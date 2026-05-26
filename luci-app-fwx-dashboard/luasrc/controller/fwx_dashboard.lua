module("luci.controller.fwx_dashboard", package.seeall)

function index()
	entry({"admin", "fwx_dashboard"}, cbi("fwx_dashboard/dashboard", {hideapplybtn=true, hidesavebtn=true, hideresetbtn=true}),
	 _("Dashboard"), 1).leaf = true
	
	entry({"admin", "dashboard_api", "get_dashboard_common"}, call("get_dashboard_common")).leaf = true
	entry({"admin", "dashboard_api", "get_init_status"}, call("get_init_status")).leaf = true
	entry({"admin", "dashboard_api", "get_daily_top_users"}, call("get_daily_top_users")).leaf = true
	entry({"admin", "dashboard_api", "get_active_users"}, call("get_active_users")).leaf = true
	entry({"admin", "dashboard_api", "get_app_type_stats"}, call("get_app_type_stats")).leaf = true
end

function get_dashboard_common()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_dashboard_common"
	req_obj.data = {}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			system_status = {},
			network_status = {},
			active_app = {total = 0, list = {}},
			interface_traffic = {interface = "wan", traffic = {}}
		})
	end
end

function get_init_status()
	local utl = require "luci.util"
	luci.http.prepare_content("application/json")

	local req_obj = {}
	req_obj.api = "get_init_status"
	req_obj.data = {}

	local resp_obj = utl.ubus("fwx", "common", req_obj)
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({init_status = 1})
	end
end

function get_daily_top_users()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_daily_top_users"
	req_obj.data = {}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			date = 0,
			total_count = 0,
			users = {}
		})
	end
end

function get_active_users()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_active_users"
	req_obj.data = {}
	
	local count = luci.http.formvalue("count")
	if count then
		req_obj.data.count = tonumber(count) or 8
	else
		req_obj.data.count = 8
	end
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			total_count = 0,
			users = {}
		})
	end
end

function get_app_type_stats()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local stat_type = luci.http.formvalue("type") or "hourly"
	
	local req_obj = {}
	req_obj.api = "get_global_app_type_stats"
	req_obj.data = {
		type = stat_type,
		limit = 10
	}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			type = stat_type,
			limit = 10,
			total_count = 0,
			types = {}
		})
	end
end
