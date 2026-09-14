module("luci.controller.fwx_traffic_stat", package.seeall)

function index()
    entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
    entry({"admin", "fwx_monitor", "traffic_stat"}, template("fwx_traffic_stat/traffic_stat"), _("Traffic Statistics"), 53).dependent = true
    entry({"admin", "traffic_stat_api", "get_today_traffic"}, call("get_today_traffic")).leaf = true
    entry({"admin", "traffic_stat_api", "get_history_traffic"}, call("get_history_traffic")).leaf = true
end

local function write_response(resp_obj, fallback)
    luci.http.prepare_content("application/json")
    if resp_obj and resp_obj.code == 2000 and resp_obj.data then
        luci.http.write_json(resp_obj.data)
    else
        luci.http.write_json(fallback)
    end
end

function get_today_traffic()
    local util = require "luci.util"
    local req_obj = {
        api = "get_global_traffic_stats",
        data = {}
    }

    write_response(util.ubus("fwx", "common", req_obj), {
        date = 0,
        is_today = 1,
        hourly_traffic = {}
    })
end

function get_history_traffic()
    local util = require "luci.util"
    local days = tonumber(luci.http.formvalue("days")) or 30
    if days < 1 then days = 1 end
    if days > 365 then days = 365 end

    local req_obj = {
        api = "get_history_traffic_stats",
        data = {
            days = days
        }
    }

    write_response(util.ubus("fwx", "common", req_obj), {
        days = days,
        list = {}
    })
end
