module("luci.controller.fwx_system", package.seeall)

local util = require("luci.util")

function index()
    entry({"admin", "fwx_advance", "system"}, template("fwx_system/system"), _("System Configuration"), 70).dependent = true
    entry({"admin", "fwx", "get_system_info"}, call("api_get_system_info"), nil).leaf = true
    entry({"admin", "fwx", "set_system_info"}, call("api_set_system_info"), nil).leaf = true
end

local function ubus_call(api, payload)
    payload = payload or {}
    payload.api = api
    return util.ubus("fwx", "common", payload) or { code = 1 }
end

function api_get_system_info()
    local json = require "luci.jsonc"
    local http = require "luci.http"
    local resp = ubus_call("get_system_info", { data = {} })
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

function api_set_system_info()
    local json = require "luci.jsonc"
    local http = require "luci.http"
    local lan_ifname = http.formvalue("lan_ifname") or ""
    local theme_mode = http.formvalue("theme_mode")
    local theme_mode_num = 0 -- 默认值为0（light）
    if theme_mode then
        theme_mode_num = tonumber(theme_mode) or 0
        -- 验证值只能是0或1
        if theme_mode_num ~= 0 and theme_mode_num ~= 1 then
            theme_mode_num = 0
        end
    end
    
    local body = {
        fwx = {
            lan_ifname = lan_ifname,
            theme_mode = theme_mode_num
        }
    }
    local resp = ubus_call("set_system_info", { data = body })
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end
