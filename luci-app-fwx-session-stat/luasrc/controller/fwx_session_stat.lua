module("luci.controller.fwx_session_stat", package.seeall)

function index()
    local global_session_node

    entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
    entry({"admin", "fwx_monitor", "session_stat"}, firstchild(), _("Session Statistics"), 51).dependent = true
    global_session_node = entry({"admin", "fwx_monitor", "session_stat", "global_session"}, template("fwx_session_stat/session_stat"), _("Global Session Count"), 20)
    global_session_node.leaf = true
    global_session_node.dependent = true
    entry({"admin", "fwx_monitor", "session_stat", "session_stat"}, alias("admin", "fwx_monitor", "session_stat", "global_session"), nil, 11).leaf = true
    entry({"admin", "session_stat_api", "get_history_session"}, call("get_history_session")).leaf = true
end

function get_history_session()
    local util = require "luci.util"
    local range = luci.http.formvalue("range") or "hour"

    luci.http.prepare_content("application/json")

    local req_obj = {
        api = "get_history_session",
        data = {
            range = range
        }
    }

    local resp_obj = util.ubus("fwx", "common", req_obj)
    if resp_obj and resp_obj.code == 2000 and resp_obj.data then
        luci.http.write_json(resp_obj.data)
    else
        luci.http.write_json({
            range = range,
            minutes = (range == "day") and 1440 or ((range == "5min") and 5 or 60),
            current = 0,
            avg = 0,
            peak = 0,
            list = {}
        })
    end
end
