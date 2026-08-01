--!strict

--[[
	Shared device-bucket helpers for Lab and Match HUDs.

	Keeps touch-pad gating and preferred-input reads in one place so PC / mobile
	/ console chrome does not drift between FunTest and Depot modes.
]]

local UserInputService = game:GetService("UserInputService")

local DeviceInput = {}

export type DeviceBucket = "Keyboard" | "Touch" | "Gamepad"

function DeviceInput.wantsTouchDrive(): boolean
	-- Touchscreen laptops report TouchEnabled too; only show the pad when touch
	-- is the preferred input or there is no keyboard to fall back on.
	if not UserInputService.TouchEnabled then
		return false
	end
	local ok, preferred = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and preferred == Enum.PreferredInput.Touch then
		return true
	end
	return not UserInputService.KeyboardEnabled
end

function DeviceInput.bucketFor(inputType: Enum.UserInputType): DeviceBucket
	if
		inputType == Enum.UserInputType.Touch
		or inputType == Enum.UserInputType.Gyro
		or inputType == Enum.UserInputType.Accelerometer
	then
		return "Touch"
	end
	if
		inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
		or inputType == Enum.UserInputType.Gamepad5
		or inputType == Enum.UserInputType.Gamepad6
		or inputType == Enum.UserInputType.Gamepad7
		or inputType == Enum.UserInputType.Gamepad8
	then
		return "Gamepad"
	end
	return "Keyboard"
end

function DeviceInput.onPreferredInputChanged(callback: () -> ())
	local service = UserInputService :: any
	if typeof(service.GetPropertyChangedSignal) == "function" then
		local ok, signal = pcall(function()
			return service:GetPropertyChangedSignal("PreferredInput")
		end)
		if ok and signal then
			return signal:Connect(callback)
		end
	end
	-- Older clients: poll infrequently from the caller’s Heartbeat if needed.
	return nil
end

return DeviceInput
