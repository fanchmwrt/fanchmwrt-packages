module("luci.controller.fwx_firewall_setting", package.seeall)

local util = require("luci.util")

function index()
    entry({"admin", "fwx_network", "firewall"}, firstchild(), _("Firewall"), 99).dependent = true
    entry({"admin", "fwx_network", "firewall", "basic"}, template("fwx_firewall_setting/basic"), _("Basic Settings"), 10).dependent = true
    entry({"admin", "fwx_network", "firewall", "get_firewall"}, call("api_get_firewall"), nil).leaf = true
    entry({"admin", "fwx_network", "firewall", "set_firewall"}, call("api_set_firewall"), nil).leaf = true
end

local function write_json(resp)
    local json = require("luci.jsonc")
    local http = require("luci.http")
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

local function read_request_data()
    local json = require("luci.jsonc")
    local http = require("luci.http")
    local data = {}
    local data_str = http.formvalue("data")

    if data_str and #data_str > 0 then
        data = json.parse(data_str) or {}
    elseif type(http.jsondata) == "function" then
        local ok, parsed = pcall(http.jsondata)
        if ok and type(parsed) == "table" then
            data = parsed
        end
    end

    if type(data) ~= "table" or next(data) == nil then
        data = {
            action = http.formvalue("action"),
            basic = {
                fullcone = http.formvalue("fullcone")
            }
        }
    end
    return data
end

local function ubus_call(api, data)
    return util.ubus("fwx", "common", {
        api = api,
        data = data or {}
    }) or { code = 1 }
end

function api_get_firewall()
    write_json(ubus_call("get_firewall", {}))
end

function api_set_firewall()
    local data = read_request_data()
    write_json(ubus_call("set_firewall", data))
end
