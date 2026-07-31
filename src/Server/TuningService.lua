--!nonstrict

--[[
	Move the feel of the truck without restarting the server.

	Every tunable value is mirrored onto an attribute of a folder in
	ReplicatedStorage. During a Studio session you select that folder in the
	Explorer, edit an attribute in the Properties pane, and the change lands in
	LabConfig on the next frame. There is no bespoke UI to maintain, because
	Studio already ships a perfectly good attribute editor.

	This works at all because LabConfig is read at the point of use. Nothing
	caches GripFront into a local at require time, so overwriting the table
	entry is genuinely all that is required.

	Two attributes are commands rather than values:

	  ACTION_Dump   flip it to print the values you have changed, formatted so
	                they can be pasted straight back into LabConfig.lua
	  ACTION_Reset  flip it to put everything back to the file defaults

	Values marked runtime = false in TuningSchema only take effect once the rig
	is rebuilt; changing one raises the build-dirty flag that DevCommands
	consumes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DevConfig = require(Shared:WaitForChild("DevConfig"))
local LabConfig = require(Shared:WaitForChild("LabConfig"))
local TuningSchema = require(Shared:WaitForChild("TuningSchema"))

local FOLDER_NAME = "LabTuning"
local DUMP_ATTRIBUTE = "ACTION_Dump"
local RESET_ATTRIBUTE = "ACTION_Reset"

local TuningService = {}

local folder: Folder? = nil
local defaults: { [string]: any } = {}
local buildDirty = false

-- Guards the write-back path. Clamping an out-of-range edit re-sets the
-- attribute, which would otherwise re-enter this handler forever.
local applying = false

local function formatValue(kind: string, value: any): string
	if kind == "number" then
		local rounded = math.floor(value * 10000 + 0.5) / 10000
		return tostring(rounded)
	elseif kind == "range" then
		return string.format("NumberRange.new(%s, %s)", tostring(value.Min), tostring(value.Max))
	elseif kind == "vector3" then
		return string.format("Vector3.new(%s, %s, %s)", tostring(value.X), tostring(value.Y), tostring(value.Z))
	end
	return tostring(value)
end

local function matchesKind(kind: string, value: any): boolean
	if kind == "number" then
		return typeof(value) == "number" and value == value and math.abs(value) < math.huge
	elseif kind == "range" then
		return typeof(value) == "NumberRange"
	elseif kind == "vector3" then
		return typeof(value) == "Vector3"
	end
	return false
end

local function writeAttribute(entry: TuningSchema.Entry, value: any)
	if not folder then
		return
	end
	applying = true
	folder:SetAttribute(entry.attribute, value)
	applying = false
end

local function onAttributeChanged(entry: TuningSchema.Entry)
	if applying or not folder then
		return
	end

	local value = folder:GetAttribute(entry.attribute)
	if not matchesKind(entry.kind, value) then
		warn(string.format("[Tuning] %s ignored: expected %s", entry.attribute, entry.kind))
		writeAttribute(entry, TuningSchema.get(LabConfig, entry.path))
		return
	end

	if entry.kind == "number" and (entry.min or entry.max) then
		local clamped = math.clamp(value, entry.min or -math.huge, entry.max or math.huge)
		if clamped ~= value then
			warn(string.format("[Tuning] %s clamped to %s", entry.attribute, tostring(clamped)))
			value = clamped
			writeAttribute(entry, clamped)
		end
	end

	TuningSchema.set(LabConfig, entry.path, value)

	if entry.runtime then
		print(string.format("[Tuning] %s = %s", entry.path, formatValue(entry.kind, value)))
	else
		buildDirty = true
		print(string.format(
			"[Tuning] %s = %s (build-time, rebuild the rig to apply)",
			entry.path,
			formatValue(entry.kind, value)
		))
	end
end

--[[
	Only the values that actually moved, so a tuning session produces a short
	patch rather than a reprint of the whole config.
]]
function TuningService.dump(): string
	local lines = { "", "===== LAB TUNING =====" }
	local changed = 0
	local group = nil

	for _, entry in TuningSchema.Entries do
		local current = TuningSchema.get(LabConfig, entry.path)
		local original = defaults[entry.path]
		if current ~= original then
			if entry.group ~= group then
				group = entry.group
				table.insert(lines, "-- " .. group)
			end
			changed += 1
			table.insert(lines, string.format(
				"  %s = %s,   -- was %s",
				entry.path,
				formatValue(entry.kind, current),
				formatValue(entry.kind, original)
			))
		end
	end

	if changed == 0 then
		table.insert(lines, "  (nothing changed from the file defaults)")
	end
	table.insert(lines, "======================")

	local text = table.concat(lines, "\n")
	print(text)
	return text
end

--[[
	Every value that has moved from the file defaults, as strings, so a run
	artifact can record the configuration that produced it. Comparing two runs
	is close to useless without knowing what was different about the truck.
]]
function TuningService.changedValues(): { [string]: string }
	local changed = {}
	for _, entry in TuningSchema.Entries do
		local current = TuningSchema.get(LabConfig, entry.path)
		if current ~= defaults[entry.path] then
			changed[entry.path] = formatValue(entry.kind, current)
		end
	end
	return changed
end

function TuningService.reset()
	for _, entry in TuningSchema.Entries do
		local original = defaults[entry.path]
		if TuningSchema.get(LabConfig, entry.path) ~= original then
			TuningSchema.set(LabConfig, entry.path, original)
			writeAttribute(entry, original)
			if not entry.runtime then
				buildDirty = true
			end
		end
	end
	print("[Tuning] restored file defaults")
end

--[[
	True once since the last call if any build-time value changed. Consumed by
	the rebuild command so the rig is only torn down when it needs to be.
]]
function TuningService.consumeBuildDirty(): boolean
	local was = buildDirty
	buildDirty = false
	return was
end

function TuningService.isBuildDirty(): boolean
	return buildDirty
end

function TuningService.init()
	if not DevConfig.isDevToolingEnabled() then
		return
	end

	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = ReplicatedStorage
	folder = created

	applying = true
	for _, entry in TuningSchema.Entries do
		local value = TuningSchema.get(LabConfig, entry.path)
		if value == nil then
			warn("[Tuning] schema path missing from LabConfig: " .. entry.path)
			continue
		end
		defaults[entry.path] = value
		created:SetAttribute(entry.attribute, value)
	end
	created:SetAttribute(DUMP_ATTRIBUTE, false)
	created:SetAttribute(RESET_ATTRIBUTE, false)
	applying = false

	for _, entry in TuningSchema.Entries do
		if defaults[entry.path] == nil then
			continue
		end
		created:GetAttributeChangedSignal(entry.attribute):Connect(function()
			onAttributeChanged(entry)
		end)
	end

	created:GetAttributeChangedSignal(DUMP_ATTRIBUTE):Connect(function()
		if applying or not created:GetAttribute(DUMP_ATTRIBUTE) then
			return
		end
		TuningService.dump()
		applying = true
		created:SetAttribute(DUMP_ATTRIBUTE, false)
		applying = false
	end)

	created:GetAttributeChangedSignal(RESET_ATTRIBUTE):Connect(function()
		if applying or not created:GetAttribute(RESET_ATTRIBUTE) then
			return
		end
		TuningService.reset()
		applying = true
		created:SetAttribute(RESET_ATTRIBUTE, false)
		applying = false
	end)

	print(string.format(
		"[Tuning] live tuning on %d values. Edit ReplicatedStorage.%s attributes in the Explorer.",
		#TuningSchema.Entries,
		FOLDER_NAME
	))
end

return TuningService
