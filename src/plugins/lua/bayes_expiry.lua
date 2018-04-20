--[[
Copyright (c) 2017, Andrew Lewis <nerf@judo.za.org>
Copyright (c) 2017, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]] --

if confighelp then
  return
end

local N = 'bayes_expiry'
local E = {}
local logger = require "rspamd_logger"
local rspamd_util = require "rspamd_util"
local lutil = require "lua_util"
local lredis = require "lua_redis"

local settings = {
  interval = 60, -- one iteration step per minute
  count = 1000, -- check up to 1000 keys on each iteration
  epsilon_common = 0.01, -- eliminate common if spam to ham rate is equal to this epsilon
  common_ttl = 10 * 86400, -- TTL of discriminated common elements
  significant_factor = 3.0 / 4.0, -- which tokens should we update
  lazy = false, -- enable lazy expiration mode
  classifiers = {},
  cluster_nodes = 0,
}

local template = {}

local function check_redis_classifier(cls, cfg)
  -- Skip old classifiers
  if cls.new_schema then
    local symbol_spam, symbol_ham
    local expiry = (cls.expiry or cls.expire)
    if cls.lazy then settings.lazy = cls.lazy end
    -- Load symbols from statfiles
    local statfiles = cls.statfile
    for _,stf in ipairs(statfiles) do
      local symbol = stf.symbol or 'undefined'

      local spam
      if stf.spam then
        spam = stf.spam
      else
        if string.match(symbol:upper(), 'SPAM') then
          spam = true
        else
          spam = false
        end
      end

      if spam then
        symbol_spam = symbol
      else
        symbol_ham = symbol
      end
    end

    if not symbol_spam or not symbol_ham or not expiry then
      return
    end
    -- Now try to load redis_params if needed

    local redis_params = {}
    if not lredis.try_load_redis_servers(cls, rspamd_config, redis_params) then
      if not lredis.try_load_redis_servers(cfg[N] or E, rspamd_config, redis_params) then
        if not lredis.try_load_redis_servers(cfg['redis'] or E, rspamd_config, redis_params) then
          return false
        end
      end
    end

    if redis_params['read_only'] then
      logger.infox(rspamd_config, 'disable expiry for classifier %s: read only redis configuration',
          symbol_spam)
      return
    end

    table.insert(settings.classifiers, {
      symbol_spam = symbol_spam,
      symbol_ham = symbol_ham,
      redis_params = redis_params,
      expiry = expiry
    })
  end
end

-- Check classifiers and try find the appropriate ones
local obj = rspamd_config:get_ucl()

local classifier = obj.classifier

if classifier then
  if classifier[1] then
    for _,cls in ipairs(classifier) do
      if cls.bayes then cls = cls.bayes end
      if cls.backend and cls.backend == 'redis' then
        check_redis_classifier(cls, obj)
      end
    end
  else
    if classifier.bayes then

      classifier = classifier.bayes
      if classifier[1] then
        for _,cls in ipairs(classifier) do
          if cls.backend and cls.backend == 'redis' then
            check_redis_classifier(cls, obj)
          end
        end
      else
        if classifier.backend and classifier.backend == 'redis' then
          check_redis_classifier(classifier, obj)
        end
      end
    end
  end
end


local opts = rspamd_config:get_all_opt(N)

if opts then
  for k,v in pairs(opts) do
    settings[k] = v
  end
end

-- In clustered setup, we need to increase interval of expiration
-- according to number of nodes in a cluster
if settings.cluster_nodes == 0 then
  local neighbours = obj.neighbours or {}
  local n_neighbours = 0
  for _,_ in pairs(neighbours) do n_neighbours = n_neighbours + 1 end
  settings.cluster_nodes = n_neighbours
end

  -- Fill template
template.count = settings.count
template.threshold = settings.threshold
template.common_ttl = settings.common_ttl
template.epsilon_common = settings.epsilon_common
template.significant_factor = settings.significant_factor
template.lazy = settings.lazy
template.expire_step = settings.interval
template.hostname = rspamd_util.get_hostname()

for k,v in pairs(template) do
  template[k] = tostring(v)
end

-- Arguments:
-- [1] = symbol pattern
-- [2] = expire value
-- [3] = cursor
-- returns new cursor
local expiry_script = [[
  local unpack_function = table.unpack or unpack

  local hash2list = function (hash)
    local res = {}
    for k, v in pairs(hash) do
      table.insert(res, k)
      table.insert(res, v)
    end
    return res
  end

  local function list2hash(list)
    local res = {}
    local k
    for i, v in ipairs(list) do
      if i % 2 == 1 then
        k = v
      else
        res[k] = v
      end
    end
    if not k then
      return
    else
      return res
    end
  end

  local expire = math.floor(KEYS[2])
  local pattern_sha1 = redis.sha1hex(KEYS[1])

  local lock_key = pattern_sha1 .. '_lock' -- Check locking
  local lock = redis.call('GET', lock_key)

  if lock then
    if lock ~= '${hostname}' then
      return 'locked by ' .. lock
    end
  end

  redis.replicate_commands()
  redis.call('SETEX', lock_key, ${expire_step}, '${hostname}')

  local cursor_key = pattern_sha1 .. '_cursor'
  local cursor = tonumber(redis.call('GET', cursor_key) or 0)

  local step = 1
  local step_key = pattern_sha1 .. '_step'
  if cursor > 0 then
    step = redis.call('GET', step_key)
    step = step and (tonumber(step) + 1) or 1
  end

  local ret = redis.call('SCAN', cursor, 'MATCH', KEYS[1], 'COUNT', '${count}')
  local next = ret[1]
  local keys = ret[2]
  local tokens = {}

  -- Expiry step statistics counters
  local nelts, extended, discriminated, sum, sum_squares, common, significant, infrequent, ttls_set =
    0,0,0,0,0,0,0,0,0

  for _,key in ipairs(keys) do
    local values = redis.call('HMGET', key, 'H', 'S')
    local ham = tonumber(values[1]) or 0
    local spam = tonumber(values[2]) or 0
    local ttl = redis.call('TTL', key)
    tokens[key] = {
      ham,
      spam,
      ttl
    }
    local total = spam + ham
    sum = sum + total
    sum_squares = sum_squares + total * total
    nelts = nelts + 1
  end

  local mean, stddev = 0, 0

  if nelts > 0 then
    mean = sum / nelts
    stddev = math.sqrt(sum_squares / nelts - mean * mean)
  end

  for key,token in pairs(tokens) do
    local ham, spam, ttl = token[1], token[2], tonumber(token[3])
    local threshold = mean
    local total = spam + ham

    if total == 0 or math.abs(ham - spam) <= total * ${epsilon_common} then
      common = common + 1
      if ttl > ${common_ttl} then
        discriminated = discriminated + 1
        redis.call('EXPIRE', key, ${common_ttl})
      end
    elseif total >= threshold and total > 0 then
      if ham / total > ${significant_factor} or spam / total > ${significant_factor} then
        significant = significant + 1
        if ${lazy} or expire < 0 then
          if ttl ~= -1 then
            redis.call('PERSIST', key)
            extended = extended + 1
          end
        else
          redis.call('EXPIRE', key, expire)
          extended = extended + 1
        end
      end
    else
      infrequent = infrequent + 1
      if expire < 0 then
        if ttl ~= -1 then
          redis.call('PERSIST', key)
          ttls_set = ttls_set + 1
        end
      elseif ttl == -1 or ttl > expire then
        redis.call('EXPIRE', key, expire)
        ttls_set = ttls_set + 1
      end
    end
  end

  -- Expiry cycle statistics counters
  local c = {nelts = 0, extended = 0, discriminated = 0, sum = 0, sum_squares = 0,
    common = 0, significant = 0, infrequent = 0, ttls_set = 0}

  local counters_key = pattern_sha1 .. '_counters'

  if cursor ~= 0 then
    local counters = list2hash(redis.call('HGETALL', counters_key))
    if counters then c = counters end
  end

  c.nelts = c.nelts + nelts
  c.extended = c.extended + extended
  c.discriminated = c.discriminated + discriminated
  c.sum = c.sum + sum
  c.sum_squares = c.sum_squares + sum_squares
  c.common = c.common + common
  c.significant = c.significant + significant
  c.infrequent = c.infrequent + infrequent
  c.ttls_set = c.ttls_set + ttls_set

  redis.call('HMSET', counters_key, unpack_function(hash2list(c)))
  redis.call('SET', cursor_key, tostring(next))
  redis.call('SET', step_key, tostring(step))
  redis.call('DEL', lock_key)

  return {
    next, step,
    {nelts, extended, discriminated, mean, stddev, common, significant, infrequent, ttls_set},
    {c.nelts, c.extended, c.discriminated, c.sum, c.sum_squares, c.common, c.significant, c.infrequent, c.ttls_set}
  }
]]

local function expire_step(cls, ev_base, worker)
  local function redis_step_cb(err, args)
    if err then
      logger.errx(rspamd_config, 'cannot perform expiry step: %s', err)
    elseif type(args) == 'table' then
      local cur = tonumber(args[1])
      local step = args[2]
      local data = args[3]
      local c_data = args[4]

      local function log_stat(cycle)
        local mode = settings.lazy and ' (lazy)' or ''
        local significant_action = (settings.lazy or cls.expiry < 0) and 'made persistent' or 'extended'
        local infrequent_action = (cls.expiry < 0) and 'made persistent' or 'ttls set'

        local c_mean, c_stddev = 0, 0
        if cycle and c_data[1] ~= 0 then
          c_mean = c_data[4] / c_data[1]
          c_stddev = math.floor(.5 + math.sqrt(c_data[5] / c_data[1] - c_mean * c_mean))
          c_mean = math.floor(.5 + c_mean)
        end

        local d = cycle and {
          'cycle in ' .. step .. ' steps', mode, c_data[1],
          c_data[7], c_data[2], significant_action,
          c_data[6], c_data[3],
          c_data[8], c_data[9], infrequent_action,
          c_mean,
          c_stddev
        } or {
          'step ' .. step, mode, data[1],
          data[7], data[2], significant_action,
          data[6], data[3],
          data[8], data[9], infrequent_action,
          data[4],
          data[5]
        }
        logger.infox(rspamd_config,
                [[finished expiry %s%s: %s items checked, %s significant (%s %s), %s common (%s discriminated), %s infrequent (%s %s), %s mean, %s std]],
                lutil.unpack(d))
      end
      log_stat(false)
      if cur == 0 then
        log_stat(true)
      end
    elseif type(args) == 'string' then
      logger.infox(rspamd_config, 'skip expiry step: %s', args)
    end
  end
  lredis.exec_redis_script(cls.script,
      {ev_base = ev_base, is_write = true},
      redis_step_cb,
      {'RS*_*', cls.expiry}
  )
end

rspamd_config:add_on_load(function (_, ev_base, worker)
  -- Exit unless we're the first 'controller' worker
  if not worker:is_primary_controller() then return end

  local unique_redis_params = {}
  -- Push redis script to all unique redis servers
  for _,cls in ipairs(settings.classifiers) do
    local seen = false
    for _,rp in ipairs(unique_redis_params) do
      if lutil.table_cmp(rp, cls.redis_params) then
        seen = true
      end
    end

    if not seen then
      table.insert(unique_redis_params, cls.redis_params)
    end
  end

  for _,rp in ipairs(unique_redis_params) do
    local script_id = lredis.add_redis_script(lutil.template(expiry_script,
        template), rp)

    for _,cls in ipairs(settings.classifiers) do
      if lutil.table_cmp(rp, cls.redis_params) then
        cls.script = script_id
      end
    end
  end

  -- Expire tokens at regular intervals
  for _,cls in ipairs(settings.classifiers) do
    rspamd_config:add_periodic(ev_base,
        settings['interval'],
        function ()
          expire_step(cls, ev_base, worker)
          return true
        end, true)
  end
end)
