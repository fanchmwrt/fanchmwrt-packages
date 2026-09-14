module("luci.controller.fwx_wireless_base_setting", package.seeall)

local util = require("luci.util")
local http = require("luci.http")
local json = require("luci.jsonc")

function index()
    if not nixio.fs.access("/etc/config/wireless") then
        return
    end
    
    entry({"admin", "fwx_wireless"}, firstchild(), _("Wireless Setting"), 30).dependent = true
    entry({"admin", "fwx_wireless", "radio"}, template("fwx_wireless_base_setting/radio_setting"), _("Wireless Radio"), 10).dependent = true
    entry({"admin", "fwx_wireless", "interface"}, template("fwx_wireless_base_setting/base_setting"), _("Wireless Interface"), 20).dependent = true
    entry({"admin", "fwx_wireless", "get_radio_info"}, call("api_get_radio_info"), nil).leaf = true
    entry({"admin", "fwx_wireless", "set_radio_info"}, post("api_set_radio_info"), nil).leaf = true
    entry({"admin", "fwx_wireless", "get_interface_info"}, call("api_get_interface_info"), nil).leaf = true
    entry({"admin", "fwx_wireless", "set_interface_info"}, post("api_set_interface_info"), nil).leaf = true
end

local function safe_json(data)
    local ok, ret = pcall(function()
        return json.stringify(data)
    end)
    if ok and ret then
        return ret
    end
    return "<json stringify failed>"
end

local function ubus_call(api, payload)
    payload = payload or {}
    payload.api = api
    return util.ubus("fwx", "common", payload) or { code = 1 }
end

local function normalize_item_list(item_list)
    local arr = {}
    local has_number_index = false

    if type(item_list) ~= "table" then
        return arr
    end

    for k, v in pairs(item_list) do
        local idx = tonumber(k)
        if idx and idx > 0 then
            arr[idx] = v
            has_number_index = true
        end
    end

    if has_number_index then
        local compact = {}
        for i = 1, #arr do
            compact[#compact + 1] = arr[i]
        end
        if #compact > 0 then
            return compact
        end
    end

    for _, v in pairs(item_list) do
        arr[#arr + 1] = v
    end
    return arr
end

local function parse_request_body(list_name)
    local body = nil
    local data_str = http.formvalue("data")
    local list_str = nil

    if data_str and #data_str > 0 then
        body = json.parse(data_str)
    else
        list_str = http.formvalue(list_name)
        if list_str and #list_str > 0 then
            local parsed_list = json.parse(list_str)
            if type(parsed_list) == "table" then
                body = {}
                body[list_name] = parsed_list
            end
        end
    end

    if (type(body) ~= "table" or next(body) == nil) and type(http.jsondata) == "function" then
        local ok, parsed = pcall(http.jsondata)
        if ok and type(parsed) == "table" and next(parsed) ~= nil then
            body = parsed
        end
    end

    if type(body) ~= "table" then
        body = {}
    end
    if type(body[list_name]) ~= "table" then
        body[list_name] = {}
    else
        body[list_name] = normalize_item_list(body[list_name])
    end

    return body
end

function api_get_interface_info()
    local resp = ubus_call("get_wireless_interface_info", { data = {} })
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

function api_get_radio_info()
    local resp = ubus_call("get_wireless_radio_info", { data = {} })
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

function api_set_radio_info()
    local body = parse_request_body("radio_list")
    local req_obj = { api = "set_wireless_radio_info", data = body }
    local resp = util.ubus("fwx", "common", req_obj)

    if not resp and type(body.radio_list) == "table" and #body.radio_list > 0 then
        local obj_radio_list = {}
        for i, item in ipairs(body.radio_list) do
            obj_radio_list[tostring(i)] = item
        end
        req_obj = { api = "set_wireless_radio_info", data = { radio_list = obj_radio_list } }
        resp = util.ubus("fwx", "common", req_obj)
    end
    if not resp then
        resp = { code = 1 }
    end

    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

function api_set_interface_info()
    local body = parse_request_body("ssid_list")
    local req_obj = { api = "set_wireless_interface_info", data = body }

    local resp = util.ubus("fwx", "common", req_obj)
    if not resp and type(body.ssid_list) == "table" and #body.ssid_list > 0 then
        local obj_ssid_list = {}
        for i, item in ipairs(body.ssid_list) do
            obj_ssid_list[tostring(i)] = item
        end
        req_obj = { api = "set_wireless_interface_info", data = { ssid_list = obj_ssid_list } }
        resp = util.ubus("fwx", "common", req_obj)
    end
    if not resp then
        resp = { code = 1 }
    end

    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end
