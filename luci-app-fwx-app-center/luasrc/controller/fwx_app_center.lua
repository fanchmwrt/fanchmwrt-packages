module("luci.controller.fwx_app_center", package.seeall)

local util = require "luci.util"
local json = require "luci.jsonc"
local http = require "luci.http"
local nfs = require "nixio.fs"
local uci = require "luci.model.uci".cursor()
local normalize_region

APP_CENTER_ROOT = "/fwx_data/app_center"
APP_CENTER_APP_LIST = "/fwx_data/app_list"
APP_CENTER_APP_CACHE = "/fwx_data/app_center/cache_data"
APP_CENTER_INSTALLED_INDEX = "/fwx_data/app_center/installed_apps.json"
APP_CENTER_CACHE = "/fwx_data/app_center/app_center_list_cache.json"
APP_CENTER_UPDATE_META = "/fwx_data/app_center/list_update_meta.json"
APP_CENTER_BACKUP_ROOT = "/fwx_data/back_up"
TMP_APP_CENTER = "/tmp/app_center"
TMP_APP_CENTER_INSTALL = "/fwx_data/app_center/install_tmp"
APP_CENTER_LOG_FILE = "/tmp/log/app_center_install.log"
APP_CENTER_ICON_ROOT = "/www/luci-static/resources/app_center"
APP_CENTER_API_BASE = "https://cloud.fanchmwrt.com/api/"
NETWORK_STATUS_FILE = "/tmp/network_status"
SERVER_SUCCESS_CODE = 20000
BOOT_CODE_OK = 2000
BOOT_CODE_KERNEL_MISMATCH = 4001
SYNC_ERR_NETWORK = 40001
SYNC_ERR_VERSION = 40002
SYNC_ERR_SERVER = 40003
SYNC_ERR_NO_PLUGIN = 40004
ICON_DOWNLOAD_TIMEOUT = 5
ERROR_LOG_NAME = "error.log"
ERROR_LOG_MAX_BYTES = 16384

SENSITIVE_KEYS = {
	Url = true,
	SHA256sum = true,
	FileName = true
}

local TRUE_STR = { ["1"] = true, ["true"] = true, ["yes"] = true, ["y"] = true, ["on"] = true }
local FALSE_STR = { ["0"] = true, ["false"] = true, ["no"] = true, ["n"] = true, ["off"] = true }
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function log(msg)
	local log_dir = tostring(APP_CENTER_LOG_FILE or ""):match("^(.+)/[^/]+$")
	if log_dir and log_dir ~= "" then
		os.execute("mkdir -p " .. log_dir:gsub(" ", "\\ ") .. " 2>/dev/null")
	end
	local f = io.open(APP_CENTER_LOG_FILE, "a")
	if f then
		f:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. tostring(msg) .. "\n")
		f:close()
	end
end

local function trim_str(v)
	if type(v) ~= "string" then return "" end
	local s = v:gsub("^%s*(.-)%s*$", "%1")
	return s
end

local function base64_encode_str(raw)
	if type(raw) ~= "string" or raw == "" then
		return ""
	end
	local bit_stream = (raw:gsub(".", function(c)
		local byte = c:byte()
		local bits = ""
		for i = 8, 1, -1 do
			if (byte % (2 ^ i) - byte % (2 ^ (i - 1))) > 0 then
				bits = bits .. "1"
			else
				bits = bits .. "0"
			end
		end
		return bits
	end) .. "0000")

	local out = bit_stream:gsub("%d%d%d?%d?%d?%d?", function(chunk)
		if #chunk < 6 then
			return ""
		end
		local val = 0
		for i = 1, 6 do
			if chunk:sub(i, i) == "1" then
				val = val + 2 ^ (6 - i)
			end
		end
		return BASE64_ALPHABET:sub(val + 1, val + 1)
	end)

	local tail = ({ "", "==", "=" })[#raw % 3 + 1]
	return out .. tail
end

local function read_file_limited(path, max_bytes)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read(max_bytes or "*a")
	f:close()
	if type(content) ~= "string" then
		return nil
	end
	return content
end

local function install_find_error_log_path(work_dir, extract_root)
	local checked = {}
	local function pick(path)
		if type(path) ~= "string" or path == "" or checked[path] then
			return nil
		end
		checked[path] = true
		local st = nfs.stat(path)
		if st and st.type == "reg" then
			return path
		end
		return nil
	end

	local p = pick((work_dir or "") .. "/" .. ERROR_LOG_NAME)
	if p then return p end
	p = pick((extract_root or "") .. "/" .. ERROR_LOG_NAME)
	if p then return p end

	local root_st = nfs.stat(extract_root or "")
	if root_st and root_st.type == "dir" then
		for f in nfs.dir(extract_root) do
			if f ~= "." and f ~= ".." then
				p = pick((extract_root or "") .. "/" .. f .. "/" .. ERROR_LOG_NAME)
				if p then return p end
			end
		end
	end
	return nil
end

local function install_read_error_log_payload(work_dir, extract_root)
	local log_path = install_find_error_log_path(work_dir, extract_root)
	if not log_path then
		return nil
	end
	local content = read_file_limited(log_path, ERROR_LOG_MAX_BYTES)
	if not content or content == "" then
		return nil
	end
	local st = nfs.stat(log_path)
	local truncated = false
	if st and st.size and st.size > #content then
		truncated = true
	end
	local encoded = base64_encode_str(content)
	if encoded == "" then
		return nil
	end
	return {
		ErrorLogBase64 = encoded,
		ErrorLogTruncated = truncated and 1 or 0
	}
end

local function parse_bool_text(s)
	local k = trim_str(tostring(s or "")):lower()
	if TRUE_STR[k] then return true end
	if FALSE_STR[k] then return false end
	return nil
end

local function bool_value(v)
	if v == nil then return nil end
	if type(v) == "boolean" then return v end
	if type(v) == "number" then return v ~= 0 end
	return parse_bool_text(v)
end

local function table_copy(src)
	if type(src) ~= "table" then return {} end
	local out = {}
	for k, v in pairs(src) do
		if type(v) == "table" then
			local sub = {}
			for sk, sv in pairs(v) do
				sub[sk] = sv
			end
			out[k] = sub
		else
			out[k] = v
		end
	end
	return out
end

local function normalize_string_list(v)
	local out = {}
	local function append_value(item)
		local s = trim_str(item)
		if s ~= "" then
			table.insert(out, s)
		end
	end
	if type(v) == "table" then
		for _, item in ipairs(v) do
			append_value(item)
		end
		return out
	end
	if type(v) == "string" then
		local s = trim_str(v)
		if s == "" then
			return out
		end
		if s:sub(1, 1) == "[" and s:sub(-1) == "]" then
			local ok, arr = pcall(json.parse, s)
			if ok and type(arr) == "table" then
				for _, item in ipairs(arr) do
					append_value(item)
				end
				return out
			end
		end
		append_value(s)
	end
	return out
end

local function normalize_detail_info(pkg)
	local info = {}
	if type(pkg) == "table" then
		local raw = pkg.DetailInfo or pkg.Detail or pkg.detail_info or pkg.detail
		if type(raw) == "table" then
			for k, v in pairs(raw) do
				info[k] = v
			end
		end
	end
	local detail_text = ""
	if type(info) == "table" then
		detail_text = trim_str(
			info.Detail or info.DetailedDesc or info.DetailDesc or info.LongDesc or info.Description or info.Desc or ((type(pkg) == "table") and (pkg.Detail or pkg.Desc)) or ""
		)
	end
	info.Detail = detail_text
	info.DetailedDesc = nil
	info.DetailDesc = nil
	info.FeatureList = normalize_string_list(info.FeatureList or info.Features or info.Feature or info.feature_list or info.features)
	info.ImageList = normalize_string_list(info.ImageList or info.Images or info.ImagePaths or info.image_list or info.images)
	return info
end

local function json_read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then return nil end
	local ok, t = pcall(json.parse, raw)
	if ok and type(t) == "table" then
		return t
	end
	return nil
end

local function json_write_file(path, t)
	if type(t) ~= "table" then return false end
	local f = io.open(path, "w")
	if not f then return false end
	local payload = json.stringify(t) or ""
	payload = payload:gsub("\\/", "/")
	f:write(payload)
	f:close()
	return true
end

local function parse_positive_int(v)
	if type(v) == "number" then
		if v > 0 then
			return math.floor(v)
		end
		return 0
	end
	if type(v) == "string" then
		local n = tonumber(trim_str(v))
		if n and n > 0 then
			return math.floor(n)
		end
	end
	return 0
end

local function read_network_status_flag()
	local f = io.open(NETWORK_STATUS_FILE, "r")
	if not f then
		return nil
	end
	local raw = trim_str(f:read("*a") or "")
	f:close()
	if raw == "1" then
		return true
	end
	if raw == "0" then
		return false
	end
	return nil
end

local function app_center_read_last_update_ts()
	local meta = json_read_file(APP_CENTER_UPDATE_META)
	if type(meta) ~= "table" then
		return 0
	end
	return parse_positive_int(meta.last_update_ts or meta.last_update_timestamp or meta.timestamp or meta.ts)
end

local function app_center_write_last_update_ts(ts)
	local n = parse_positive_int(ts)
	if n <= 0 then
		return false
	end
	nfs.mkdir(APP_CENTER_ROOT)
	return json_write_file(APP_CENTER_UPDATE_META, {
		last_update_ts = n,
		updated_at = os.date("%Y-%m-%d %H:%M:%S", n)
	})
end

local function read_first_line(path)
	local f = io.open(path, "r")
	if not f then return "" end
	local s = f:read("*l") or ""
	f:close()
	return trim_str(s)
end

local function get_release_date_for_app_center()
	local f = io.open("/etc/fwx_release", "r")
	if not f then
		return ""
	end
	for line in f:lines() do
		local s = trim_str((line or ""):gsub("\r", ""))
		s = s:gsub("^\239\187\191", "")
		if s ~= "" and s:sub(1, 1) ~= "#" then
			local v = s:match("^RELEASE_DATE%s*=%s*(.-)%s*$")
			if v then
				v = trim_str(v)
				if #v >= 2 then
					local first = v:sub(1, 1)
					local last = v:sub(-1)
					if (first == "'" and last == "'") or (first == '"' and last == '"') then
						v = v:sub(2, -2)
					end
				end
				f:close()
				return trim_str(v)
			end
		end
	end
	f:close()
	return ""
end

local function app_boot_data_path(name)
	return APP_CENTER_APP_LIST .. "/" .. name .. "/boot_data"
end

local function parse_boot_code_value(v)
	if type(v) == "number" then
		return v
	end
	if type(v) == "string" then
		local n = tonumber(trim_str(v))
		if n then
			return n
		end
	end
	return nil
end

local function read_boot_code(name)
	local p = app_boot_data_path(name)
	local st = nfs.stat(p)
	if not st or st.type ~= "reg" then
		log("boot_data not found: name=" .. tostring(name) .. " path=" .. p)
		return nil
	end
	local plain = read_first_line(p)
	local plain_code = parse_boot_code_value(plain)
	if plain_code ~= nil then
		log("boot_data loaded plain: name=" .. tostring(name) .. " code=" .. tostring(plain_code))
		return plain_code
	end
	local f = io.open(p, "r")
	local raw = f and (f:read("*a") or "") or ""
	if f then f:close() end
	if raw == "" then
		log("boot_data parse failed: name=" .. tostring(name) .. " path=" .. p .. " reason=empty")
		return nil
	end
	local ok, parsed = pcall(json.parse, raw)
	if ok then
		if type(parsed) == "table" then
			local code = parse_boot_code_value(parsed.code)
			if code ~= nil then
				log("boot_data loaded json object: name=" .. tostring(name) .. " code=" .. tostring(code))
				return code
			end
		else
			local code = parse_boot_code_value(parsed)
			if code ~= nil then
				log("boot_data loaded json value: name=" .. tostring(name) .. " code=" .. tostring(code))
				return code
			end
		end
	end
	log("boot_data parse failed: name=" .. tostring(name) .. " path=" .. p .. " reason=invalid")
	return nil
end

local function write_boot_code_ok(app_dir)
	return json_write_file(app_dir .. "/boot_data", { code = BOOT_CODE_OK })
end

local function write_text_file(path, value)
	local f = io.open(path, "w")
	if not f then
		return false
	end
	f:write(tostring(value or ""))
	f:close()
	return true
end

local function remove_file(path)
	pcall(nfs.unlink, path)
end

local function write_app_requirements(app_dir, pkg)
	local kernel_version = trim_str((type(pkg) == "table" and pkg.KernelVersion) or "")
	local min_fw_version = trim_str((type(pkg) == "table" and pkg.MinFwVersion) or "")
	local kernel_file = app_dir .. "/required_kernel_version"
	local fw_file = app_dir .. "/required_min_fw_version"
	if kernel_version == "" then
		remove_file(kernel_file)
	else
		write_text_file(kernel_file, kernel_version)
	end
	if min_fw_version == "" then
		remove_file(fw_file)
	else
		write_text_file(fw_file, min_fw_version)
	end
end

local function normalize_config_path(path)
	if type(path) ~= "string" then return nil end
	local p = trim_str(path)
	if p == "" then return nil end
	p = p:gsub("^['\"]+", ""):gsub("['\"]+$", "")
	p = p:gsub("/+", "/")
	if p:sub(1, 1) ~= "/" then return nil end
	if p == "/" then return nil end
	p = p:gsub("/+$", "")
	if p:find("..", 1, true) then return nil end
	return p
end

local function append_config_path(paths, seen, path)
	local p = normalize_config_path(path)
	if not p then return end
	if not seen[p] then
		seen[p] = true
		table.insert(paths, p)
	end
end

local function collect_config_paths_from_value(v, paths, seen)
	if v == nil then return end
	if type(v) == "table" then
		for _, item in ipairs(v) do
			append_config_path(paths, seen, item)
		end
		return
	end
	if type(v) ~= "string" then return end
	local s = trim_str(v)
	if s == "" then return end
	if s:sub(1, 1) == "[" and s:sub(-1) == "]" then
		local ok, arr = pcall(json.parse, s)
		if ok and type(arr) == "table" then
			for _, item in ipairs(arr) do
				append_config_path(paths, seen, item)
			end
			return
		end
	end
	s = s:gsub("^%[", ""):gsub("%]$", "")
	s = s:gsub("[\"']", "")
	for token in s:gmatch("[^,%s;|]+") do
		append_config_path(paths, seen, token)
	end
end

local function pkg_config_paths(pkg)
	if type(pkg) ~= "table" then return {} end
	local paths, seen = {}, {}
	collect_config_paths_from_value(pkg.ConfigPathList, paths, seen)
	return paths
end

local function pkg_has_config(pkg)
	if type(pkg) ~= "table" then return false end
	if bool_value(pkg.HasConfig) == true then
		return true
	end
	if #pkg_config_paths(pkg) > 0 then
		return true
	end
	return false
end

local function copy_pkg_for_meta(pkg)
	if type(pkg) ~= "table" then return {} end
	local out = {}
	for k, v in pairs(pkg) do
		if type(k) == "string" and not SENSITIVE_KEYS[k] then
			out[k] = v
		end
	end
	return out
end

local function normalize_installed_row(name, row)
	local out = table_copy(row)
	out.Name = name
	out.Version = trim_str(out.Version or "")
	out.InstallDate = trim_str(out.InstallDate or "")
	local cfg = pkg_config_paths(out)
	if #cfg > 0 then
		out.ConfigPathList = cfg
	else
		out.ConfigPathList = nil
	end
	out.HasConfig = (pkg_has_config(out) or #cfg > 0) and 1 or 0
	out.Installed = 1
	out.InstalledVersion = out.Version
	out.DetailInfo = normalize_detail_info(out)
	return out
end

local function installed_index_read()
	local t = json_read_file(APP_CENTER_INSTALLED_INDEX)
	if type(t) ~= "table" then
		return {}
	end
	local out = {}
	for _, row in ipairs(t) do
		if type(row) == "table" then
			local name = trim_str(row.Name or "")
			if name ~= "" then
				table.insert(out, normalize_installed_row(name, row))
			end
		end
	end
	return out
end

local function installed_index_write(list)
	if type(list) ~= "table" then return false end
	nfs.mkdir(APP_CENTER_ROOT)
	local out = {}
	for _, row in ipairs(list) do
		if type(row) == "table" then
			local name = trim_str(row.Name or "")
			if name ~= "" then
				table.insert(out, normalize_installed_row(name, row))
			end
		end
	end
	return json_write_file(APP_CENTER_INSTALLED_INDEX, out)
end

local function installed_index_find(name)
	local safe_name = trim_str(name or "")
	if safe_name == "" then return nil end
	for _, row in ipairs(installed_index_read()) do
		if row.Name == safe_name then
			return row
		end
	end
	return nil
end

local function installed_index_upsert(name, pkg, version)
	local safe_name = trim_str(name or "")
	if safe_name == "" then return false end
	local list = installed_index_read()
	local target_idx = nil
	local target = nil
	for i, row in ipairs(list) do
		if row.Name == safe_name then
			target_idx = i
			target = table_copy(row)
			break
		end
	end
	if not target then
		target = {}
	end
	local from_pkg = copy_pkg_for_meta(pkg)
	for k, v in pairs(from_pkg) do
		target[k] = v
	end
	target.Name = safe_name
	target.Version = trim_str(version or target.Version or "")
	target.InstallDate = os.date("%Y-%m-%d %H:%M:%S")
	local normalized = normalize_installed_row(safe_name, target)
	if target_idx then
		list[target_idx] = normalized
	else
		table.insert(list, normalized)
	end
	table.sort(list, function(a, b) return a.Name < b.Name end)
	return installed_index_write(list)
end

local function installed_index_remove(name)
	local safe_name = trim_str(name or "")
	if safe_name == "" then return false end
	local out = {}
	for _, row in ipairs(installed_index_read()) do
		if row.Name ~= safe_name then
			table.insert(out, row)
		end
	end
	return installed_index_write(out)
end

local function app_uninstall_script_path(name)
	return APP_CENTER_APP_LIST .. "/" .. name .. "/uninstall.sh"
end

local function is_standard_installed_app(name)
	local app_dir = APP_CENTER_APP_LIST .. "/" .. name
	local app_st = nfs.stat(app_dir)
	if not app_st or app_st.type ~= "dir" then
		return false
	end
	local uninstall_st = nfs.stat(app_uninstall_script_path(name))
	if not uninstall_st or uninstall_st.type ~= "reg" then
		return false
	end
	return true
end

local function parse_depends_list(depends)
	local out = {}
	local seen = {}
	local function add_dep(dep)
		if type(dep) ~= "string" then return end
		local name = trim_str(dep)
		if name == "" then return end
		if not seen[name] then
			seen[name] = true
			table.insert(out, name)
		end
	end
	if type(depends) == "table" then
		for _, item in ipairs(depends) do
			if type(item) == "table" then
				add_dep(item.Name or item.name)
			else
				add_dep(item)
			end
		end
	elseif type(depends) == "string" then
		for dep in depends:gmatch("[^,%s;|]+") do
			add_dep(dep)
		end
	end
	return out
end

local function get_missing_depends(app_name, depends)
	local missing = {}
	for _, dep_name in ipairs(parse_depends_list(depends)) do
		if dep_name ~= app_name and not is_standard_installed_app(dep_name) then
			table.insert(missing, dep_name)
		end
	end
	return missing
end

local function collect_installed_rows()
	local index_map = {}
	for _, row in ipairs(installed_index_read()) do
		index_map[row.Name] = row
	end
	local rows = {}
	if nfs.stat(APP_CENTER_APP_LIST) then
		for name in nfs.dir(APP_CENTER_APP_LIST) do
			if name ~= "." and name ~= ".." and is_standard_installed_app(name) then
				local row = table_copy(index_map[name] or {})
				row.Name = name
				local disk_ver = read_first_line(APP_CENTER_APP_LIST .. "/" .. name .. "/version")
				if disk_ver ~= "" then
					row.Version = disk_ver
				end
				local disk_date = read_first_line(APP_CENTER_APP_LIST .. "/" .. name .. "/install_date")
				if disk_date ~= "" then
					row.InstallDate = disk_date
				end
				table.insert(rows, normalize_installed_row(name, row))
			end
		end
	end
	table.sort(rows, function(a, b) return a.Name < b.Name end)
	installed_index_write(rows)
	return rows
end

local function cache_write(cache)
	nfs.mkdir(APP_CENTER_ROOT)
	if type(cache) ~= "table" then return false end
	local out = {
		Url = cache.Url or "",
		PackageList = cache.PackageList or {},
		_version = cache._version or "",
		_arch = cache._arch or ""
	}
	return json_write_file(APP_CENTER_CACHE, out)
end

local function cache_read()
	local cache = json_read_file(APP_CENTER_CACHE)
	if type(cache) ~= "table" then
		log("cache_read: invalid cache content")
		return nil
	end
	if type(cache.Url) ~= "string" then
		log("cache_read: missing Url")
		return nil
	end
	if type(cache.PackageList) ~= "table" then
		log("cache_read: missing PackageList")
		return nil
	end
	return {
		Url = cache.Url,
		PackageList = cache.PackageList,
		_version = cache._version or "",
		_arch = cache._arch or ""
	}
end

local function build_cache_data(data, version, arch)
	if type(data) ~= "table" then return nil end
	if type(data.Url) ~= "string" then return nil end
	if type(data.PackageList) ~= "table" then return nil end
	local package_list = {}
	for _, pkg in ipairs(data.PackageList) do
		if type(pkg) == "table" then
			local name = trim_str(pkg.Name or "")
			if name ~= "" then
				local row = table_copy(pkg)
				row.DetailInfo = normalize_detail_info(row)
				table.insert(package_list, row)
			end
		end
	end
	return {
		Url = data.Url,
		PackageList = package_list,
		_version = version or "",
		_arch = arch or ""
	}
end

local function cache_find_package(cache, name)
	if type(cache) ~= "table" or type(cache.PackageList) ~= "table" then
		return nil
	end
	local safe_name = trim_str(name or "")
	if safe_name == "" then
		return nil
	end
	for _, pkg in ipairs(cache.PackageList) do
		if type(pkg) == "table" and trim_str(pkg.Name or "") == safe_name then
			return pkg
		end
	end
	return nil
end

local function resolve_app_alias(name, pkg)
	local alias = ""
	if type(pkg) == "table" then
		alias = trim_str(pkg.Alias or pkg.alias or "")
		if alias == "" then
			alias = trim_str(pkg.Name or pkg.name or "")
		end
	end
	if alias == "" then
		alias = trim_str(name or "")
	end
	return alias
end

local function write_app_error(code, msg, name, pkg, extra_data)
	local data = {
		Name = trim_str(name or ""),
		Alias = resolve_app_alias(name, pkg)
	}
	if type(extra_data) == "table" then
		for k, v in pairs(extra_data) do
			data[k] = v
		end
	end
	http.write(json.stringify({ code = code, msg = msg, data = data }))
end

local function build_merged_data(cache, installed_rows, arch, version, from_local_cache, region)
	local installed_map = {}
	for _, row in ipairs(installed_rows or {}) do
		installed_map[row.Name] = row
	end

	local installed_from_cache = {}
	local installed_local_only = {}
	local not_installed = {}
	local seen = {}

	local cache_list = (cache and cache.PackageList) or {}
	for _, pkg in ipairs(cache_list) do
		if type(pkg) == "table" then
			local name = trim_str(pkg.Name or "")
			if name ~= "" and not seen[name] then
				local row = table_copy(pkg)
				local inst = installed_map[name]
				if inst then
					local installed_ver = trim_str(inst.Version or "")
					local latest_ver = trim_str(row.Version or "")
					local has_new_version = (installed_ver ~= "" and latest_ver ~= "" and installed_ver ~= latest_ver)
					row.Installed = 1
					row.InstalledVersion = installed_ver
					row.HasNewVersion = has_new_version and 1 or 0
					row.InstallDate = inst.InstallDate or ""
					row.HasConfig = inst.HasConfig or 0
					if inst.ConfigPathList then
						row.ConfigPathList = inst.ConfigPathList
					end
					row.DetailInfo = normalize_detail_info(row)
					table.insert(installed_from_cache, row)
				else
					row.Installed = 0
					row.InstalledVersion = ""
					row.HasNewVersion = 0
					row.DetailInfo = normalize_detail_info(row)
					table.insert(not_installed, row)
				end
				seen[name] = true
			end
		end
	end

	for _, inst in ipairs(installed_rows or {}) do
		local name = trim_str(inst.Name or "")
		if name ~= "" and not seen[name] then
			local row = table_copy(inst)
			row.Installed = 1
			row.InstalledVersion = inst.Version or ""
			row.HasNewVersion = 0
			if not row.Version or row.Version == "" then
				row.Version = row.InstalledVersion
			end
			row.DetailInfo = normalize_detail_info(row)
			table.insert(installed_local_only, row)
			seen[name] = true
		end
	end

	local out_list = {}
	for _, row in ipairs(not_installed) do
		table.insert(out_list, row)
	end
	for _, row in ipairs(installed_from_cache) do
		table.insert(out_list, row)
	end
	for _, row in ipairs(installed_local_only) do
		table.insert(out_list, row)
	end

	return {
		Url = (cache and cache.Url) or "",
		PackageList = out_list,
		_version = version or (cache and cache._version) or "",
		_arch = arch or (cache and cache._arch) or "",
		Region = normalize_region(region),
		_from_local_cache = from_local_cache and true or false
	}
end

local function apply_boot_code_after_merge(data)
	if type(data) ~= "table" or type(data.PackageList) ~= "table" then
		return data
	end
	for _, row in ipairs(data.PackageList) do
		if type(row) == "table" then
			local name = trim_str(row.Name or "")
			local installed = bool_value(row.Installed) == true
			if installed and name ~= "" and is_standard_installed_app(name) then
				local boot_code = read_boot_code(name)
				row.BootCode = boot_code
				row.boot_code = boot_code
				log("apply boot_code after merge: name=" .. name .. " boot_code=" .. tostring(boot_code))
			else
				row.BootCode = nil
				row.boot_code = nil
			end
		end
	end
	return data
end

local function sanitize_for_view(data)
	if type(data) ~= "table" then return data end
	local out = {}
	for k, v in pairs(data) do
		if k == "Url" then
			out[k] = v
		elseif k ~= "PackageList" and not SENSITIVE_KEYS[k] then
			out[k] = v
		end
	end
	local plist = {}
	for _, p in ipairs(data.PackageList or {}) do
		if type(p) == "table" then
			local row = {}
			for pk, pv in pairs(p) do
				if not SENSITIVE_KEYS[pk] then
					row[pk] = pv
				end
			end
			table.insert(plist, row)
		end
	end
	out.PackageList = plist
	return out
end

local function get_arch_and_version()
	local arch, version = nil, nil
	local f = io.open("/etc/openwrt_release", "r")
	if f then
		for line in f:lines() do
			local k, v = line:match("^([%w_]+)='([^']*)'")
			if k == "DISTRIB_ARCH" then
				arch = v and trim_str(v) or ""
			elseif k == "DISTRIB_RELEASE" then
				version = v and trim_str(v) or ""
			end
		end
		f:close()
	end
	return arch, version
end

normalize_region = function(v)
	local s = trim_str(v or ""):lower()
	if s == "cn" or s == "zh" or s == "zh_cn" or s == "zh-hans" then
		return "cn"
	end
	if s == "en" or s == "en_us" or s == "en-us" or s == "english" then
		return "en"
	end
	return ""
end

local function detect_request_region()
	local raw_query_region = trim_str(http.formvalue("region") or "")
	local from_query = normalize_region(raw_query_region)
	if from_query ~= "" then
		log("region detect: source=query, raw=" .. raw_query_region .. ", normalized=" .. from_query)
		return from_query
	end
	local raw_accept_lang = trim_str(http.getenv("HTTP_ACCEPT_LANGUAGE") or "")
	local accept_lang = raw_accept_lang:lower()
	if accept_lang:find("zh", 1, true) then
		log("region detect: source=accept_language, raw=" .. raw_accept_lang .. ", normalized=cn")
		return "cn"
	end
	log("region detect: source=default, raw=" .. raw_accept_lang .. ", normalized=en")
	return "en"
end

local function resolve_region_by_luci_lang(detected_region)
	local lang = trim_str((uci:get("luci", "main", "lang") or "")):lower()
	local detected_raw = trim_str(detected_region or ""):lower()
	if lang == "" or lang == "auto" then
		local out = detected_raw:find("cn", 1, true) and "cn" or "en"
		log("region resolve: luci_lang=" .. tostring(lang) .. ", mode=auto_detect, detected_raw=" .. tostring(detected_raw) .. ", final=" .. tostring(out))
		return out
	end
	local fixed = lang:find("cn", 1, true) and "cn" or "en"
	log("region resolve: luci_lang=" .. tostring(lang) .. ", mode=fixed, final=" .. tostring(fixed))
	return fixed
end

local function version_check_disabled(v)
	local s = trim_str(v or "")
	return (s == "" or s == "0.0.0")
end

local function parse_version_triplet(v)
	local s = trim_str(v or "")
	local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
	if not a or not b or not c then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c)
end

local function version_triplet_ge(a, b)
	local a1, a2, a3 = parse_version_triplet(a)
	local b1, b2, b3 = parse_version_triplet(b)
	if not a1 or not b1 then
		return nil
	end
	if a1 ~= b1 then return a1 > b1 end
	if a2 ~= b2 then return a2 > b2 end
	return a3 >= b3
end

local function get_current_firmware_version()
	local raw = read_first_line("/etc/fwx_version")
	log("raw version = " .. raw)
	if raw == "" then
		return ""
	end
	raw = trim_str(raw)
	if raw:match("^[0-9]+%.[0-9]+%.[0-9]+$") then
		log("valid ok")
		return raw
	end
	log("validate error")
	return ""
end

local function check_pkg_runtime_requirements(pkg)
	if type(pkg) ~= "table" then
		return true
	end
	local req_kernel = trim_str(pkg.KernelVersion or "")
	local req_fw = trim_str(pkg.MinFwVersion or "")
	log("req kernel = "..req_kernel .. "req fw = ".. req_fw)

	if not version_check_disabled(req_kernel) then
		local kf = io.popen("uname -r 2>/dev/null")
		local current_kernel = trim_str(kf and (kf:read("*l") or "") or "")
		if kf then kf:close() end
		if current_kernel == "" then
			return false, 4014, "failed to get current kernel version"
		end
		if current_kernel ~= req_kernel then
			return false, 4012, "kernel version mismatch, please reinstall this plugin"
		end
	end

	if not version_check_disabled(req_fw) then
		local current_fw = get_current_firmware_version()
		log("current fw version = " ..current_fw)
		log("req fw = " .. req_fw)
		local ok = version_triplet_ge(current_fw, req_fw)
		if ok == nil then
			return false, 4014, "firmware version format invalid"
		end
		if not ok then
			return false, 4013, "firmware version mismatch, please reinstall this plugin"
		end
	end

	return true
end

local function fetch_server_list(arch, version, region)
	local timeout_seconds = 20
	local net_online = read_network_status_flag()
	if net_online == false then
		log("fetch_server_list skip: network offline by " .. tostring(NETWORK_STATUS_FILE))
		return false, SYNC_ERR_NETWORK, "network offline", nil
	end
	local api_base = tostring(APP_CENTER_API_BASE or ""):gsub("/+$", "")
	local release_date = get_release_date_for_app_center()
	local api_url = api_base .. "/appcenter/get_app_list?arch=" .. util.urlencode(arch) .. "&version=" .. util.urlencode(version) .. "&release_date=" .. util.urlencode(release_date)
	local req_region = normalize_region(region)
	if req_region ~= "" then
		api_url = api_url .. "&region=" .. util.urlencode(req_region)
	end
	log("fetch_server_list request: arch=" .. tostring(arch) .. ", version=" .. tostring(version) .. ", release_date=" .. tostring(release_date) .. ", region=" .. tostring(req_region))
	log("fetch_server_list url=" .. tostring(api_url))
	local started_at = parse_positive_int(os.time())
	local wget_cmd = "wget -q --no-check-certificate -T " .. tostring(timeout_seconds) .. " -O - '" .. api_url:gsub("'", "'\\''") .. "' 2>&1"
	local wf = io.popen(wget_cmd)
	local raw = wf and wf:read("*a") or ""
	local close_ok, close_reason, close_code = nil, nil, nil
	if wf then
		close_ok, close_reason, close_code = wf:close()
	end
	local ended_at = parse_positive_int(os.time())
	local elapsed = 0
	if started_at > 0 and ended_at > 0 and ended_at >= started_at then
		elapsed = ended_at - started_at
	end
	log("fetch_server_list raw_len=" .. tostring(#raw))
	log("fetch_server_list raw=" .. tostring(raw))
	log("fetch_server_list close_ok=" .. tostring(close_ok) .. ", close_reason=" .. tostring(close_reason) .. ", close_code=" .. tostring(close_code) .. ", elapsed=" .. tostring(elapsed))
	local ok, resp = pcall(json.parse, raw)
	if ok and type(resp) == "table" and resp.code == SERVER_SUCCESS_CODE and type(resp.data) == "table" then
		if type(resp.data.Url) == "string" and type(resp.data.PackageList) == "table" then
			if #resp.data.PackageList == 0 then
				return false, SYNC_ERR_NO_PLUGIN, "no plugins for firmware", api_url
			end
			return true, resp.data, api_url
		end
		return false, SYNC_ERR_SERVER, "invalid server data", api_url
	end
	if raw == "" then
		if elapsed >= timeout_seconds then
			return false, SYNC_ERR_NETWORK, "request timeout", api_url
		end
		return false, SYNC_ERR_SERVER, "empty response", api_url
	end
	if ok and type(resp) == "table" then
		local server_code = parse_positive_int(resp.code)
		local server_msg = trim_str(resp.msg)
		if server_code == 40004 or (server_msg ~= "" and server_msg:find("no plugin", 1, true)) then
			return false, SYNC_ERR_NO_PLUGIN, server_msg, api_url
		end
		if server_msg ~= "" then
			return false, SYNC_ERR_SERVER, server_msg, api_url
		end
		return false, SYNC_ERR_SERVER, "server error", api_url
	end
	local lower_raw = trim_str(raw):lower()
	if lower_raw:find("timed out", 1, true) then
		return false, SYNC_ERR_NETWORK, "network error", api_url
	end
	return false, SYNC_ERR_SERVER, "invalid server response", api_url
end

local function backup_app_config_paths(app_name, paths)
	if type(paths) ~= "table" or #paths == 0 then
		return true, "no config paths"
	end
	local safe_name = tostring(app_name or ""):gsub("[/\\]", "_")
	if safe_name == "" then
		return false, "invalid app name"
	end
	local app_backup_dir = APP_CENTER_BACKUP_ROOT .. "/" .. safe_name
	if os.execute("mkdir -p " .. app_backup_dir:gsub(" ", "\\ ") .. " 2>/dev/null") ~= 0 then
		return false, "failed to create backup dir"
	end
	local copied = 0
	for _, src in ipairs(paths) do
		local st = nfs.stat(src)
		if st then
			local rel = src:gsub("^/+", "")
			if rel ~= "" then
				local dst = app_backup_dir .. "/" .. rel
				local parent = dst:match("(.+)/[^/]+$") or app_backup_dir
				os.execute("mkdir -p " .. parent:gsub(" ", "\\ ") .. " 2>/dev/null")
				os.execute("rm -rf " .. dst:gsub(" ", "\\ ") .. " 2>/dev/null")
				if os.execute("cp -a " .. src:gsub(" ", "\\ ") .. " " .. dst:gsub(" ", "\\ ") .. " 2>/dev/null") == 0 then
					copied = copied + 1
				end
			end
		end
	end
	return true, tostring(copied)
end

local function app_center_ensure_tmp()
	os.execute("mkdir -p " .. TMP_APP_CENTER:gsub(" ", "\\ ") .. " " .. TMP_APP_CENTER_INSTALL:gsub(" ", "\\ ") .. " 2>/dev/null")
end

local function clear_app_cache_root()
	local st = nfs.stat(APP_CENTER_APP_CACHE)
	if not st then
		os.execute("mkdir -p " .. APP_CENTER_APP_CACHE:gsub(" ", "\\ ") .. " 2>/dev/null")
		return true
	end
	if st.type ~= "dir" then
		os.execute("rm -rf " .. APP_CENTER_APP_CACHE:gsub(" ", "\\ ") .. " 2>/dev/null")
		os.execute("mkdir -p " .. APP_CENTER_APP_CACHE:gsub(" ", "\\ ") .. " 2>/dev/null")
		return true
	end
	local removed = 0
	for name in nfs.dir(APP_CENTER_APP_CACHE) do
		if name ~= "." and name ~= ".." then
			local p = APP_CENTER_APP_CACHE .. "/" .. name
			if os.execute("rm -rf " .. p:gsub(" ", "\\ ") .. " 2>/dev/null") == 0 then
				removed = removed + 1
			end
		end
	end
	log("app_cache cleared: removed=" .. tostring(removed))
	return true
end

local function app_center_pkg_path(name)
	return TMP_APP_CENTER .. "/" .. name .. ".fpk"
end

local function app_center_extract_dir(name)
	return TMP_APP_CENTER_INSTALL .. "/" .. name
end

local function app_center_icon_src_path(name)
	return APP_CENTER_APP_CACHE .. "/" .. name .. "/icon.png"
end

local function app_center_icon_web_dir(name)
	return APP_CENTER_ICON_ROOT .. "/" .. name
end

local function app_center_icon_link_path(name)
	return app_center_icon_web_dir(name) .. "/icon.png"
end

local function resolve_icon_download_url(base_url, name)
	local safe_name = trim_str(name or "")
	if safe_name == "" then
		return nil
	end
	local base = trim_str(base_url or "")
	if base == "" then
		return nil
	end
	base = base:gsub("/+$", "")
	return base .. "/app_logos/" .. safe_name .. ".png"
end

local function download_icon_file(url, dst_path)
	if trim_str(url or "") == "" then
		return false
	end
	local function run_download_once(target_url)
		local esc = dst_path:gsub(" ", "\\ ")
		local ret = os.execute("wget -q --no-check-certificate -T " .. tostring(ICON_DOWNLOAD_TIMEOUT) .. " -O " .. esc .. " '" .. target_url .. "' >/dev/null 2>/dev/null")
		if ret == 0 then
			return true
		end
		ret = os.execute("uclient-fetch --no-check-certificate -T " .. tostring(ICON_DOWNLOAD_TIMEOUT) .. " -O " .. esc .. " '" .. target_url .. "' >/dev/null 2>/dev/null")
		return ret == 0
	end

	os.execute("rm -f " .. dst_path:gsub(" ", "\\ ") .. " 2>/dev/null")
	local ok = run_download_once(url)
	if not ok and url:match("^https://") then
		local http_url = "http://" .. url:sub(9)
		ok = run_download_once(http_url)
		if ok then
			log("icon download fallback to http success: url=" .. tostring(http_url))
		end
	end
	if not ok then return false end
	local st = nfs.stat(dst_path)
	return st and st.type == "reg" and st.size and st.size > 0
end

local function ensure_icon_symlink(name)
	local icon_src = app_center_icon_src_path(name)
	local st = nfs.stat(icon_src)
	if not st or st.type ~= "reg" then
		return false
	end
	local web_dir = app_center_icon_web_dir(name)
	local link_path = app_center_icon_link_path(name)
	os.execute("mkdir -p " .. web_dir:gsub(" ", "\\ ") .. " 2>/dev/null")
	os.execute("rm -rf " .. link_path:gsub(" ", "\\ ") .. " 2>/dev/null")
	return os.execute("ln -sf " .. icon_src:gsub(" ", "\\ ") .. " " .. link_path:gsub(" ", "\\ ") .. " 2>/dev/null") == 0
end

local function sync_icon_for_package(base_url, pkg)
	if type(pkg) ~= "table" then
		log("icon sync skip: invalid package row")
		return "skip"
	end
	local name = trim_str(pkg.Name or "")
	local with_icon = bool_value(pkg.WithIcon) == true
	if name == "" then
		log("icon sync skip: empty name")
		return "skip"
	end
	if not with_icon then
		log("icon sync skip: name=" .. name .. ", with_icon=0")
		return "skip"
	end
	local download_url = resolve_icon_download_url(base_url, name)
	if not download_url then
		log("icon url invalid: name=" .. name)
		return "fail"
	end
	local cache_dir = APP_CENTER_APP_CACHE .. "/" .. name
	os.execute("mkdir -p " .. cache_dir:gsub(" ", "\\ ") .. " 2>/dev/null")
	local dst = app_center_icon_src_path(name)
	if not download_icon_file(download_url, dst) then
		log("icon download failed: name=" .. name .. ", url=" .. tostring(download_url))
		return "fail"
	end
	if not ensure_icon_symlink(name) then
		log("icon symlink failed: name=" .. name .. ", src=" .. dst)
		return "fail"
	end
	return "ok"
end

local function sync_app_requirements_for_package(pkg)
	if type(pkg) ~= "table" then
		return
	end
	local name = trim_str(pkg.Name or "")
	if name == "" then
		return
	end
	local app_dir = APP_CENTER_APP_LIST .. "/" .. name
	local st = nfs.stat(app_dir)
	if not st or st.type ~= "dir" then
		return
	end
	write_app_requirements(app_dir, pkg)
end

local function sync_icon_files(cache)
	if type(cache) ~= "table" or type(cache.PackageList) ~= "table" then
		return
	end
	os.execute("mkdir -p " .. APP_CENTER_ICON_ROOT:gsub(" ", "\\ ") .. " 2>/dev/null")
	local ok_count, fail_count, skip_count = 0, 0, 0
	for _, pkg in ipairs(cache.PackageList) do
		sync_app_requirements_for_package(pkg)
		local status = sync_icon_for_package(cache.Url, pkg)
		if status == "ok" then
			ok_count = ok_count + 1
		elseif status == "fail" then
			fail_count = fail_count + 1
		else
			skip_count = skip_count + 1
		end
	end
	log("icon sync summary: ok=" .. tostring(ok_count) .. ", fail=" .. tostring(fail_count) .. ", skip=" .. tostring(skip_count))
end

local function download_fpk(url, dest_path)
	log("download url = " .. url);
	local esc = dest_path:gsub(" ", "\\ ")
	local wget_ret = os.execute("wget -q --no-check-certificate -T 60 -O " .. esc .. " '" .. url:gsub("'", "'\\''") .. "'")
	if wget_ret ~= 0 then
		wget_ret = os.execute("uclient-fetch -O " .. esc .. " '" .. url:gsub("'", "'\\''") .. "'")
	end
	if wget_ret ~= 0 then
		return false
	end
	local st = nfs.stat(dest_path)
	return st and st.size and st.size > 0
end

local function install_sha256_of_file(path)
	local esc = path:gsub(" ", "\\ ")
	local actual = nil
	local shaf = io.popen("sha256sum " .. esc .. " 2>/dev/null")
	if shaf then
		local line = shaf:read("*l") or ""
		shaf:close()
		actual = line:match("^([%a-fA-F0-9]+)")
	end
	if not actual then
		shaf = io.popen("openssl dgst -sha256 -hex " .. esc .. " 2>/dev/null")
		if shaf then
			local line = shaf:read("*l") or ""
			shaf:close()
			actual = line:match("([%a-fA-F0-9]+)%s*$")
		end
	end
	return actual and actual:lower() or nil
end

local function install_verify_sha256(path, expected_sha)
	if not expected_sha or expected_sha == "" then
		return true
	end
	local actual = install_sha256_of_file(path)
	if not actual then
		return false, "unavailable"
	end
	if actual ~= expected_sha:lower() then
		log("sha256 mismatch: expected=" .. expected_sha .. ", actual=" .. actual)
		return false, "mismatch"
	end
	return true
end

local function install_extract_fpk(pkg_path, extract_dir)
	os.execute("rm -rf " .. extract_dir:gsub(" ", "\\ ") .. " 2>/dev/null")
	os.execute("mkdir -p " .. extract_dir:gsub(" ", "\\ ") .. " 2>/dev/null")
	return os.execute("tar -xzf " .. pkg_path:gsub(" ", "\\ ") .. " -C " .. extract_dir:gsub(" ", "\\ ") .. " 2>/dev/null") == 0
end

local function install_locate_install_sh(root_dir)
	local install_sh, work_dir, result_path = nil, root_dir, nil
	for f in nfs.dir(root_dir) do
		if f ~= "." and f ~= ".." then
			local sub = root_dir .. "/" .. f
			local st = nfs.stat(sub)
			if st and st.type == "dir" then
				local ish = sub .. "/install.sh"
				if nfs.stat(ish) then
					install_sh = ish
					work_dir = sub
					result_path = sub .. "/result.code"
					break
				end
			end
		end
	end
	if not install_sh and nfs.stat(root_dir .. "/install.sh") then
		install_sh = root_dir .. "/install.sh"
		work_dir = root_dir
		result_path = root_dir .. "/result.code"
	end
	return install_sh, work_dir, result_path
end


local function install_run_install_sh(install_sh, work_dir, result_path)
	log("running install.sh: " .. install_sh .. " in " .. work_dir .. " to " .. result_path)
	local work_st = nfs.stat(work_dir)
	if not work_st or work_st.type ~= "dir" then
		log("invalid install work_dir: " .. tostring(work_dir))
		return "4000"
	end
	local esc_work_dir = work_dir:gsub(" ", "\\ ")
	local pwdf = io.popen("cd " .. esc_work_dir .. " && pwd")
	if pwdf then
		local current_dir = trim_str(pwdf:read("*l") or "")
		pwdf:close()
		log("current dir before install.sh: " .. current_dir)
	end
	if result_path and result_path ~= "" then
		os.execute("rm -f " .. result_path:gsub(" ", "\\ ") .. " 2>/dev/null")
	end
	os.execute("rm -f " .. (work_dir .. "/error.log"):gsub(" ", "\\ ") .. " 2>/dev/null")
	os.execute("chmod +x " .. install_sh:gsub(" ", "\\ ") .. " 2>/dev/null")
	os.execute("cd " .. esc_work_dir .. " && /bin/sh " .. install_sh:gsub(" ", "\\ ") .. " </dev/null >> " .. APP_CENTER_LOG_FILE:gsub(" ", "\\ ") .. " 2>&1")

	local result_code = nil
	if result_path then
		local rcf = io.open(result_path, "r")
		if rcf then
			result_code = trim_str(rcf:read("*l") or "")
			rcf:close()
		end
	end
	if not result_code or result_code == "" then
		result_code = "4000"
	end
	return result_code
end



local function install_save_app_meta(work_dir, app_dir, version, pkg)
	nfs.mkdir(app_dir)
	local uninstall_src = work_dir .. "/uninstall.sh"
	if not nfs.stat(uninstall_src) then
		for f in nfs.dir(work_dir) do
			if f:match("uninstall") then
				uninstall_src = work_dir .. "/" .. f
				break
			end
		end
	end
	if not nfs.stat(uninstall_src) then
		return false, "uninstall.sh not found"
	end
	if os.execute("cp " .. uninstall_src:gsub(" ", "\\ ") .. " " .. app_dir .. "/uninstall.sh 2>/dev/null") ~= 0 then
		return false, "failed to copy uninstall.sh"
	end
	os.execute("chmod +x " .. app_dir .. "/uninstall.sh 2>/dev/null")
	local init_src = work_dir .. "/init.sh"
	if not nfs.stat(init_src) then
		for f in nfs.dir(work_dir) do
			if f:match("init") then
				local p = work_dir .. "/" .. f
				local st = nfs.stat(p)
				if st and st.type == "reg" then 
					init_src = p
					break
				end
			end
		end
	end
	local init_st = nfs.stat(init_src)
	if init_st and init_st.type == "reg" then
		if os.execute("cp " .. init_src:gsub(" ", "\\ ") .. " " .. app_dir .. "/init.sh 2>/dev/null") ~= 0 then
			return false, "failed to copy init.sh"
		end
		os.execute("chmod +x " .. app_dir .. "/init.sh 2>/dev/null")
	end
	local luci_apps_src = work_dir .. "/luci-apps"
	local luci_apps_st = nfs.stat(luci_apps_src)
	if luci_apps_st and luci_apps_st.type == "dir" then
		local luci_apps_dst = app_dir .. "/luci-apps"
		os.execute("rm -rf " .. luci_apps_dst:gsub(" ", "\\ ") .. " 2>/dev/null")
		if os.execute("cp -fr " .. luci_apps_src:gsub(" ", "\\ ") .. " " .. luci_apps_dst:gsub(" ", "\\ ") .. " 2>/dev/null") ~= 0 then
			log("copy luci-apps failed: src=" .. tostring(luci_apps_src) .. ", dst=" .. tostring(luci_apps_dst))
		end
	end
	local vf = io.open(app_dir .. "/version", "w")
	if not vf then return false, "failed to write version" end
	vf:write(version or "")
	vf:close()
	local df = io.open(app_dir .. "/install_date", "w")
	if not df then return false, "failed to write install_date" end
	df:write(os.date("%Y-%m-%d %H:%M:%S"))
	df:close()
	write_app_requirements(app_dir, pkg)
	if not write_boot_code_ok(app_dir) then
		return false, "failed to write boot_data"
	end
	return true
end

local function build_get_app_list_data(arch, version, need_sync, region)
	local cache = cache_read()
	local sync_ok = false
	local sync_code = nil
	local sync_msg = nil
	if need_sync then
		clear_app_cache_root()
		local ok, data_or_code, data_or_msg, api_url = fetch_server_list(arch, version, region)
		if ok then
			local cache_data = build_cache_data(data_or_code, version, arch)
			if cache_data and cache_write(cache_data) then
				sync_icon_files(cache_data)
				local cache_after_sync = cache_read()
				if cache_after_sync then
					cache = cache_after_sync
					sync_ok = true
					log("get_app_list sync success: api=" .. tostring(api_url))
				else
					sync_code = SYNC_ERR_SERVER
					sync_msg = "cache readback failed"
					log("get_app_list sync failed: " .. tostring(sync_msg))
				end
			else
				sync_code = SYNC_ERR_SERVER
				sync_msg = "failed to write cache"
				log("get_app_list sync failed: " .. tostring(sync_msg))
			end
		else
			sync_code = parse_positive_int(data_or_code)
			if sync_code <= 0 then
				sync_code = SYNC_ERR_SERVER
			end
			sync_msg = tostring(data_or_msg)
			log("get_app_list sync failed: " .. tostring(sync_msg) .. ", api=" .. tostring(api_url))
		end
	end
	local installed = collect_installed_rows()
	local from_local_cache = (not need_sync) or (not sync_ok)
	local merged = build_merged_data(cache, installed, arch, version, from_local_cache, region)
	log("begin merge")
	merged = apply_boot_code_after_merge(merged)
	local row_count = 0
	local boot_count = 0
	for _, row in ipairs((merged and merged.PackageList) or {}) do
		row_count = row_count + 1
		local code = nil
		if type(row) == "table" then
			code = row.boot_code
			if code == nil then
				code = row.BootCode
			end
		end
		if code ~= nil then
			boot_count = boot_count + 1
		end
	end
	log("get_app_list merged summary: rows=" .. tostring(row_count) .. ", boot_code_rows=" .. tostring(boot_count))
	return merged, sync_ok, sync_code, sync_msg
end

function index()
	entry({"admin", "fwx_app_center"}, template("fwx_app_center/app_center"), _("App Center"), 15).dependent = true
	entry({"admin", "app_center_api", "get_app_list"}, call("api_get_app_list")).leaf = true
	entry({"admin", "app_center_api", "get_installed_apps"}, call("api_get_installed_apps")).leaf = true
	entry({"admin", "app_center_api", "install_app"}, call("api_install_app")).leaf = true
	entry({"admin", "app_center_api", "uninstall_app"}, call("api_uninstall_app")).leaf = true
end

function api_get_app_list()
	http.prepare_content("application/json")
	local ok, err = xpcall(function()
		local raw_sync = http.formvalue("sync")
		local raw_region = http.formvalue("region")
		log("api_get_app_list enter: raw_sync=" .. tostring(raw_sync) .. ", raw_region=" .. tostring(raw_region))
		local need_sync = bool_value(raw_sync) == true
		local detected_region = detect_request_region()
		local region = resolve_region_by_luci_lang(detected_region)
		log("api_get_app_list params: sync=" .. tostring(need_sync) .. ", detected_region=" .. tostring(detected_region) .. ", final_region=" .. tostring(region))
		local arch, version = get_arch_and_version()
		log("api_get_app_list env: arch=" .. tostring(arch) .. ", version=" .. tostring(version))
		if not arch or arch == "" then
			log("api_get_app_list fail: arch empty")
			http.write(json.stringify({ code = SYNC_ERR_VERSION, msg = "failed to get arch" }))
			return
		end
		if not version or version == "" then
			log("api_get_app_list fail: version empty")
			http.write(json.stringify({ code = SYNC_ERR_VERSION, msg = "failed to get version" }))
			return
		end
		local data, sync_ok, sync_code, sync_msg = build_get_app_list_data(arch, version, need_sync, region)
		local last_update_ts = app_center_read_last_update_ts()
		if need_sync and sync_ok then
			local now_ts = parse_positive_int(os.time())
			if now_ts > 0 then
				if app_center_write_last_update_ts(now_ts) then
					last_update_ts = now_ts
				else
					log("api_get_app_list: write update meta failed")
				end
			end
		end
		if type(data) == "table" then
			data.last_update_ts = last_update_ts
		end
		log("api_get_app_list merged: sync_ok=" .. tostring(sync_ok) .. ", sync_msg=" .. tostring(sync_msg))
		if need_sync and not sync_ok then
			http.write(json.stringify({
				code = sync_code or SYNC_ERR_SERVER,
				msg = sync_msg or "sync failed",
				data = sanitize_for_view(data)
			}))
			return
		end
		http.write(json.stringify({
			code = 2000,
			msg = "ok",
			data = sanitize_for_view(data)
		}))
	end, function(e)
		local tb = e
		if debug and debug.traceback then
			tb = debug.traceback(e, 2)
		end
		return tb
	end)
	if not ok then
		log("api_get_app_list exception: " .. tostring(err))
		http.write(json.stringify({ code = 5000, msg = "internal error" }))
	end
end

function api_get_installed_apps()
	http.prepare_content("application/json")
	http.write(json.stringify({ code = 2000, data = { installed = collect_installed_rows() } }))
end

function api_install_app()
	http.prepare_content("application/json")
	local name = trim_str(http.formvalue("name"))
	if name == "" then
		log("install failed: name is required")
		write_app_error(4000, "name is required", name, nil)
		return
	end

	app_center_ensure_tmp()
	local tmp_pkg = app_center_pkg_path(name)
	local extract_root = app_center_extract_dir(name)
	local app_dir = APP_CENTER_APP_LIST .. "/" .. name

	local cached = cache_read()
	if not cached then
		write_app_error(4006, "app list cache not found, please click update list", name, nil)
		return
	end
	local base_url = cached.Url
	if base_url == "" then
		write_app_error(4006, "download url not configured in server", name, nil)
		return
	end
	local pkg = cache_find_package(cached, name)
	if type(pkg) ~= "table" then
		write_app_error(4008, "app not found", name, nil)
		return
	end
	local req_ok, req_code, req_msg = check_pkg_runtime_requirements(pkg)
	if not req_ok then
		log("install blocked by runtime requirements, name=" .. name .. ", code=" .. tostring(req_code) .. ", msg=" .. tostring(req_msg))
		write_app_error(req_code or 4014, req_msg or "runtime version check failed", name, pkg)
		return
	end
	local missing_depends = get_missing_depends(name, pkg.Depends)
	if #missing_depends > 0 then
		local msg = "please install dependency apps first: " .. table.concat(missing_depends, ",")
		log("install failed: missing depends, name=" .. name .. ", missing=" .. table.concat(missing_depends, ","))
		write_app_error(4010, msg, name, pkg, { missing_depends = missing_depends })
		return
	end

	local runtime_arch, runtime_release = get_arch_and_version()
	local release = trim_str(runtime_release or cached._version or "")
	local arch = trim_str(runtime_arch or cached._arch or "")
	if release == "" or arch == "" then
		write_app_error(4001, "failed to get release or arch", name, pkg)
		return
	end
	local file_name = trim_str(pkg.FileName or "")
	if file_name == "" then
		file_name = name .. ".fpk"
	end
	base_url = base_url:gsub("/+$", "")
	local url = base_url .. "/fpk/" .. release .. "/" .. arch .. "/" .. file_name
	local expected_sha = trim_str(pkg.SHA256sum or "")
	local pkg_version = trim_str(pkg.Version or "")

	nfs.mkdir(APP_CENTER_ROOT)
	nfs.mkdir(APP_CENTER_APP_LIST)
	if nfs.stat(app_dir) then
		if is_standard_installed_app(name) then
			write_app_error(4005, "app already installed", name, pkg)
			return
		end
		os.execute("rm -rf " .. app_dir:gsub(" ", "\\ "))
	end

	if not download_fpk(url, tmp_pkg) then
		pcall(nfs.unlink, tmp_pkg)
		write_app_error(4002, "download failed", name, pkg)
		return
	end

	local sha_ok, sha_err = install_verify_sha256(tmp_pkg, expected_sha)
	if not sha_ok then
		pcall(nfs.unlink, tmp_pkg)
		if sha_err == "unavailable" then
			write_app_error(4007, "checksum verification unavailable", name, pkg)
		else
			write_app_error(4007, "checksum verification failed", name, pkg)
		end
		return
	end

	if not install_extract_fpk(tmp_pkg, extract_root) then
		pcall(nfs.unlink, tmp_pkg)
		os.execute("rm -rf " .. extract_root:gsub(" ", "\\ "))
		write_app_error(4003, "extract failed", name, pkg)
		return
	end
	pcall(nfs.unlink, tmp_pkg)

	local install_sh, work_dir, result_path = install_locate_install_sh(extract_root)
	if not install_sh then
		os.execute("rm -rf " .. extract_root:gsub(" ", "\\ "))
		write_app_error(4003, "install.sh not found", name, pkg)
		return
	end
	local result_code = install_run_install_sh(install_sh, work_dir, result_path)
	if result_code ~= "2000" then
		local extra_data = install_read_error_log_payload(work_dir, extract_root)
		os.execute("rm -rf " .. extract_root:gsub(" ", "\\ "))
		write_app_error(4003, "install failed: " .. tostring(result_code), name, pkg, extra_data)
		return
	end

	local meta_ok, meta_err = install_save_app_meta(work_dir, app_dir, pkg_version, pkg)
	if not meta_ok then
		local extra_data = install_read_error_log_payload(work_dir, extract_root)
		os.execute("rm -rf " .. app_dir:gsub(" ", "\\ "))
		os.execute("rm -rf " .. extract_root:gsub(" ", "\\ "))
		write_app_error(4003, tostring(meta_err or "install metadata save failed"), name, pkg, extra_data)
		return
	end

	installed_index_upsert(name, pkg, pkg_version)
	sync_icon_for_package(base_url, pkg)
	os.execute("rm -rf " .. extract_root:gsub(" ", "\\ "))
	http.write(json.stringify({ code = 2000, msg = "ok" }))
end

function api_uninstall_app()
	http.prepare_content("application/json")
	local name = trim_str(http.formvalue("name"))
	local keep_config = bool_value(http.formvalue("keep_config")) and true or false
	if name == "" then
		write_app_error(4000, "name is required", name, nil)
		return
	end

	local has_config = false
	local config_paths = {}
	local inst = installed_index_find(name)
	if inst then
		has_config = pkg_has_config(inst)
		config_paths = pkg_config_paths(inst)
	end
	local dependent_apps = {}
	local dependent_aliases = {}
	for _, row in ipairs(collect_installed_rows()) do
		local row_name = trim_str((row and row.Name) or "")
		if row_name ~= "" and row_name ~= name then
			for _, dep_name in ipairs(parse_depends_list(row.Depends)) do
				if dep_name == name then
					table.insert(dependent_apps, row_name)
					table.insert(dependent_aliases, resolve_app_alias(row_name, row))
					break
				end
			end
		end
	end
	if #dependent_apps > 0 then
		local msg = "uninstall failed, dependent apps: " .. table.concat(dependent_apps, ",")
		log("uninstall blocked by depends, name=" .. name .. ", dependent_apps=" .. table.concat(dependent_apps, ","))
		write_app_error(4011, msg, name, inst, { dependent_apps = dependent_apps, dependent_aliases = dependent_aliases })
		return
	end
	if not has_config then
		keep_config = false
	end

	local app_dir = APP_CENTER_APP_LIST .. "/" .. name
	if not nfs.stat(app_dir) then
		write_app_error(4004, "app not installed", name, inst)
		return
	end
	local uninstall_sh = app_uninstall_script_path(name)
	if not nfs.stat(uninstall_sh) then
		write_app_error(4004, "uninstall.sh not found", name, inst)
		return
	end

	if keep_config then
		backup_app_config_paths(name, config_paths)
	end

	local keep_flag = keep_config and "1" or "0"
	local esc_uninstall = uninstall_sh:gsub(" ", "\\ ")
	os.execute("KEEP_CONFIG=" .. keep_flag .. " FWX_KEEP_CONFIG=" .. keep_flag .. " " .. esc_uninstall .. " > /dev/null 2>&1")
	os.execute("rm -rf " .. app_dir:gsub(" ", "\\ "))
	installed_index_remove(name)
	http.write(json.stringify({ code = 2000, msg = "ok" }))
end
