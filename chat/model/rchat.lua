-- Copyright (C) 2013 MaMa

local redis = require "database.redis"
local cjson = require "cjson"

local setmetatable = setmetatable
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local get_instance = get_instance
local ngx_null = ngx.null
local json_encode = cjson.encode
local localtime = ngx.localtime
local time = ngx.time
local unpack = unpack


local _M = getfenv()

local config = get_instance().loader:config('redis')
local channel_pref = config.channel_pref
local contact_pref = config.contact_pref
local unread_pref = config.unread_pref
local online_user_list = config.online_user_list
local subscribe_timeout = config.subscribe_timeout
local client_pref = config.client_pref
local hold_pref = config.hold_pref
local delay_pref = config.delay_pref
local online_pref = config.online_pref
local max_network_delay = config.max_network_delay
local longpoll_timeout = config.longpoll_timeout

local hold_init_value = "1"
local hold_value = "2"

function new(self, uid, groups)
    local red, chs = redis:connect(config), nil

    if uid then
        chs = { channel_pref .. uid }

        if groups then
            for _i, g in ipairs(groups) do
                chs[#chs + 1] = channel_pref .. g
            end
        end

        get_instance().debug:log_debug('subscribe', unpack(chs))
        red:subscribe(unpack(chs))
        red:set_timeout(subscribe_timeout)
    end

    return setmetatable({
        red = red,
        uid = uid,
        groups = groups,
        chs = chs,
    }, { __index = _M } )
end

function subscribe(self, timeout)
    local red = self.red

    if timeout then
        red:set_timeout(timeout)
    end

    local data, err = red:read_reply()
    if data and data ~= ngx_null then
        return data and data[3]
    end

    return nil, err
end

function publish(self, channel, data)
    local red = self.red

    return red:publish(channel_pref .. channel, json_encode(data))
end

function send(self, id, sender, acceptor, message, sender_username, acceptor_username)
    local red, now = self.red, time()

    local package = {
        _t = "msg",
        data = {
            id = id,
            sender = sender,
            acceptor = acceptor,
            message = message,
            status = 1,
            time = localtime(),
        },
    }
    package.data.sender_username, package.data.acceptor_username = nil, acceptor_username
    local sender_data = json_encode(package)
    package.data.sender_username, package.data.acceptor_username = sender_username, nil
    local acceptor_data = json_encode(package)

    red:init_pipeline()
    -- send message
    red:publish(channel_pref .. sender, sender_data)
    red:publish(channel_pref .. acceptor, acceptor_data)
    -- contact
    red:zadd(contact_pref .. sender, now, acceptor)
    red:zadd(contact_pref .. acceptor, now, sender)
    local res = red:commit_pipeline()

    -- unread
    unread(self, acceptor, sender, 'incr')

    return res
end

function unread(self, master, contact, op)
    local red, key = self.red, unread_pref .. master
    if "incr" == op then
        return red:hincrby(key, contact, 1)
    elseif "clear" == op then
        return red:hdel(key, contact)
    end
end

function view(self, sender, acceptor)
    local red = self.red

    local package = {
        _t = "view",
        data = {
            sender = sender,
            acceptor = acceptor,
        },
    }
    local data = json_encode(package)

    -- unread
    unread(self, acceptor, sender, 'clear')

    -- send message
    return red:publish(channel_pref .. acceptor, data)
end

function contact(self, user, num)
    local red = self.red

    local users = red:zrevrange(contact_pref .. user, 0, num -1 or 9)

    if users and users ~= ngx_null then
        local users_online = online(self, users)

        red:init_pipeline()
        for _i, u in ipairs(users) do
            red:hget(unread_pref .. user, u)
        end
        local results = red:commit_pipeline()

        local ret = {}
        for i, u in ipairs(users) do
            ret[#ret + 1] = {
                uid = u,
                online = users_online[u],
                unread = results and results[i] and results[i] ~= ngx_null
                    and tonumber(results[i]) or 0
            }
        end

        return ret
    end

    return {}
end

function client_online(self, uid, client, status)
    local red, now, hkey = self.red, time(), online_pref .. uid

    red:zadd(online_user_list, now, uid)
    return red:hset(hkey, client, now)
end

function client_offline(self, uid, client)
    local red, now, hkey = self.red, time(), online_pref .. uid

    red:hdel(hkey, client)

    local clients = red:hgetall(hkey)
    if clients and clients ~= ngx_null then
        local online, deadline = false, now - longpoll_timeout - max_network_delay
        for i = 1, #clients, 2 do
            if tonumber(clients[i + 1]) < deadline then
                red:hdel(hkey, clients[i])
            else
                online = true
            end
        end

        if not online then
            red:zrem(online_user_list, uid)
        end
    end
end

function online(self, users)
    local red = self.red
    red:init_pipeline()
    for _i, user in ipairs(users) do
        red:zscore(online_user_list, user)
    end

    local results, err = red:commit_pipeline()

    local ret, deadline = {}, time() - longpoll_timeout - max_network_delay
    for i, user in ipairs(users) do
        if results and tonumber(results[i]) and tonumber(results[i]) >= deadline then
            ret[user] = true
        else
            ret[user] = false
        end
    end

    return ret
end

function online_all(self, num)
    local red, deadline = self.red, time() - longpoll_timeout - max_network_delay

    red:zremrangebyscore(online_user_list, "-inf", deadline)
    local users, err = red:zrevrange(online_user_list, 0, num and (num - 1) or -1)

    return users and users or {}
end

function client(self, uid)
    local red = self.red

    local client = red:incr(client_pref .. uid)
    red:set(hold_pref .. uid .. ":" .. client, hold_init_value, "EX", max_network_delay)

    return client
end

function hold_delay(self, uid, client)
    local red, key = self.red, hold_pref .. uid .. ":" .. client

    return red:set(key, hold_value, "EX", max_network_delay)
end

function check_hold(self, uid, client)
    local data, err = self.red:get(hold_pref .. uid .. ":" .. client)
    --get_instance().debug:log_debug('check hold', uid, client, data, hold_value == data)
    return hold_value == data and true or nil
end

function delay_message(self, uid, client, msg)
    local red, key = self.red, delay_pref .. "uid" .. ":" .. client

    red:lpush(key, msg)
    return red:expire(key, max_network_delay * 2)
end

function longpoll(self, uid, client)
    local red, key = self.red, delay_pref .. "uid" .. ":" .. client

    red:set_timeout((longpoll_timeout + max_network_delay) * 1000)
    local res, err = red:brpop(key, longpoll_timeout)
    red:set_timeout(red.config.timeout)

    if res == ngx_null then
        return nil, 'timeout'
    elseif res then
        return res[2]
    end
end

-- check delay while client connecting
-- 1. check delay available
-- 2. online client
function connect(self, uid, client)
    local red, hold_key = self.red, hold_pref .. uid .. ":" .. client

    local ex = red:get(hold_key)

    local ok, err
    if ex == hold_init_value then
        ok, err = red:set(hold_key, hold_value,
            "EX", longpoll_timeout + max_network_delay)
    elseif ex == hold_value then
        ok, err = red:set(hold_key, hold_value,
            "EX", longpoll_timeout + max_network_delay, "XX")
    end

    if ok then
        client_online(self, uid, client)

        return ok, ex == hold_init_value
    end
end

function close(self)
    local red, chs = self.red, self.chs

    if chs then
        red:unsubscribe(unpack(chs))
        get_instance().debug:log_debug('unsubscribe', unpack(chs))
    end

    return red:keepalive()
end