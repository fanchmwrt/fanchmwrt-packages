module("luci.controller.fwx_feature", package.seeall)

function index()
	entry({"admin", "fwx_advance"}, firstchild(), _("Advance Settings"), 90).dependent = true
	entry({"admin", "fwx_advance", "fwx_feature"},
		template("fwx_feature/feature"),
		_("Feature Library"), 50).dependent = true
	entry({"admin", "fwx_advance", "fwx_feature", "info"}, call("get_feature_info"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "class_list"}, call("get_feature_class_list"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "online_config"}, call("get_feature_online_config"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "online_save"}, call("set_feature_online_config"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "online_list"}, call("get_feature_online_list"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "online_start"}, call("start_feature_online_update"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "online_status"}, call("get_feature_online_update_status"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "custom_list"}, call("get_custom_feature_list"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "custom_class_list"}, call("get_custom_feature_class_list"), nil).leaf = true
	entry({"admin", "fwx_advance", "fwx_feature", "custom_save"}, call("set_custom_feature_list"), nil).leaf = true
end


function get_feature_info()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	luci.http.prepare_content("application/json")
	local resp_obj = utl.ubus("fwx", "common", {
		api = "get_feature_info", data = {}
	})
	luci.http.write(json.stringify(resp_obj or {code = 4000}))
end

local function write_fwx_response(api, data)
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	luci.http.prepare_content("application/json")
	local resp_obj = utl.ubus("fwx", "common", {
		api = api, data = data or {}
	})
	luci.http.write(json.stringify(resp_obj or {code = 4000}))
end

function get_feature_online_config()
	write_fwx_response("get_feature_online_config", {})
end

function set_feature_online_config()
	write_fwx_response("set_feature_online_config", {
		token = luci.http.formvalue("token") or ""
	})
end

function get_feature_online_list()
	local lang = luci.http.formvalue("lang") or "cn"
	local refresh = tonumber(luci.http.formvalue("refresh") or "0") or 0
	if lang ~= "cn" and lang ~= "en" then
		lang = "cn"
	end
	write_fwx_response("get_feature_online_list", {
		lang = lang,
		device_lang = luci.http.formvalue("device_lang") or "",
		refresh = refresh
	})
end

function start_feature_online_update()
	local lang = luci.http.formvalue("lang") or "cn"
	if lang ~= "cn" and lang ~= "en" then
		lang = "cn"
	end
	write_fwx_response("start_feature_online_update", {
		id = luci.http.formvalue("id") or "",
		lang = lang,
		md5 = luci.http.formvalue("md5") or ""
	})
end

function get_feature_online_update_status()
	write_fwx_response("get_feature_online_update_status", {})
end

function get_custom_feature_list()
	write_fwx_response("get_custom_feature", {})
end

function get_custom_feature_class_list()
	write_fwx_response("get_custom_feature_class_list", {})
end

function set_custom_feature_list()
	local json = require "luci.jsonc"
	local data_str = luci.http.formvalue("data")
	local ok, data_obj = pcall(json.parse, data_str or "")
	if not ok then
		data_obj = nil
	end
	if type(data_obj) ~= "table" or type(data_obj.app_list) ~= "table" then
		luci.http.prepare_content("application/json")
		luci.http.write(json.stringify({code = 4000, data = {error = "invalid request data"}}))
		return
	end
	write_fwx_response("set_custom_feature", data_obj)
end

function get_feature_class_list()
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.CopyRight = "www.fanchmwrt.com"
	req_obj.api = "class_list"
	req_obj.data = {}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write(json.stringify(resp_obj.data))
	else
		luci.http.write(json.stringify({class_list = {}}))
	end
end
