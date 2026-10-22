module("luci.controller.fwx_fastnat", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local translate = require("luci.i18n").translate
local util = require "luci.util"

function index()
    entry({"admin", "fwx_network"}, firstchild(), _("Network Setting"), 29).dependent = true
    entry({"admin", "fwx_network", "fastnat"}, template("fwx_fastnat/fastnat"), _("Fastnat"), 40).dependent = true
    entry({"admin", "fwx_network", "fastnat_status"}, call("api_get_status"), nil).leaf = true
    entry({"admin", "fwx_network", "fastnat_config"}, post("api_set_config"), nil).leaf = true
end

local function ubus_call(api, data)
    local resp = util.ubus("fwx", "common", { api = api, data = data or {} })
    if not resp then
        resp = { code = 1, message = translate("Fastnat service is unavailable") }
    elseif resp.message then
        resp.message = translate(resp.message)
    end
    http.prepare_content("application/json")
    http.write(json.stringify(resp))
end

function api_get_status()
    ubus_call("get_fastnat_status")
end

function api_set_config()
    local data = {}
    for _, key in ipairs({ "enabled", "dpi_compat" }) do
        local value = http.formvalue(key)
        if value ~= nil then
            if value ~= "0" and value ~= "1" then
                http.prepare_content("application/json")
                http.write(json.stringify({ code = 1, message = translate("Invalid switch value") }))
                return
            end
            data[key] = tonumber(value)
        end
    end
    ubus_call("set_fastnat_config", data)
end
