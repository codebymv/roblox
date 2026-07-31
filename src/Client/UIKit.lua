--!nonstrict

--[[
	The bits of UI construction every client file was reimplementing.

	Between LabUI, DebugOverlay, MatchUI, DepotUI and Nameplates there were
	forty-odd hand-rolled Instance.new calls building the same three things: a
	rounded panel, a left-aligned text label, and a rounded button. Roughly two
	fifths of each client file was scaffolding, and the colours drifted between
	them because each one hard-coded its own.

	Two things live here:

	  constructors  props-table builders, so a call site reads as a description
	                of the element rather than eight lines of assignment
	  setters       guarded writes, used by refresh loops

	The setters matter more than they look. LabUI.refresh ran about forty
	unconditional property writes ten times a second, almost all of them
	assigning the value that was already there. A property write is not free on
	the Roblox side even when the value is unchanged, so comparing first is the
	cheaper path.
]]

local UIKit = {}

UIKit.Theme = {
	Panel = Color3.fromRGB(16, 18, 22),
	PanelTransparency = 0.25,
	PanelCorner = 8,

	Text = Color3.fromRGB(235, 235, 235),
	Muted = Color3.fromRGB(170, 178, 190),
	Dim = Color3.fromRGB(140, 148, 160),
	Accent = Color3.fromRGB(255, 210, 110),

	Button = Color3.fromRGB(48, 54, 64),
	ButtonCorner = 6,
	Positive = Color3.fromRGB(60, 110, 70),
	Danger = Color3.fromRGB(96, 54, 54),

	Good = Color3.fromRGB(90, 210, 120),
	Warn = Color3.fromRGB(240, 200, 70),
	Bad = Color3.fromRGB(240, 110, 60),
}

local Theme = UIKit.Theme

--[[
	Parent is applied last on purpose. Setting properties on an instance that is
	already in the tree costs a change notification each; setting them first and
	parenting once does not.
]]
--[[
	CornerRadius is not a property of Frame or TextButton, so it is intercepted
	here and turned into the UICorner that panels and buttons want anyway.
]]
local RESERVED = { Parent = true, CornerRadius = true }

local function apply(instance: Instance, props: { [string]: any }?): Instance
	if not props then
		return instance
	end

	for key, value in props do
		if not RESERVED[key] then
			(instance :: any)[key] = value
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end

	return instance
end

UIKit.apply = apply

function UIKit.corner(instance: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.PanelCorner)
	corner.Parent = instance
	return corner
end

function UIKit.screen(name: string, parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent
	return gui
end

-- A plain container with no chrome. For rows and tracks inside a panel.
function UIKit.frame(props: { [string]: any }?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Panel
	frame.BorderSizePixel = 0
	return apply(frame, props) :: Frame
end

-- The standard rounded, semi-transparent card.
function UIKit.panel(props: { [string]: any }?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = Theme.Panel
	frame.BackgroundTransparency = Theme.PanelTransparency
	frame.BorderSizePixel = 0
	apply(frame, props)
	UIKit.corner(frame, props and props.CornerRadius or Theme.PanelCorner)
	return frame
end

function UIKit.label(props: { [string]: any }?): TextLabel
	local element = Instance.new("TextLabel")
	element.BackgroundTransparency = 1
	element.Font = Enum.Font.GothamMedium
	element.TextSize = 14
	element.TextColor3 = Theme.Text
	element.TextXAlignment = Enum.TextXAlignment.Left
	element.Text = ""
	return apply(element, props) :: TextLabel
end

function UIKit.button(props: { [string]: any }?): TextButton
	local element = Instance.new("TextButton")
	element.BackgroundColor3 = Theme.Button
	element.BorderSizePixel = 0
	element.AutoButtonColor = true
	element.Font = Enum.Font.GothamBold
	element.TextSize = 16
	element.TextColor3 = Color3.fromRGB(240, 240, 240)
	element.Text = ""
	apply(element, props)
	UIKit.corner(element, props and props.CornerRadius or Theme.ButtonCorner)
	return element
end

-- ------------------------------------------------------- guarded setters

function UIKit.set(instance: Instance, property: string, value: any)
	if (instance :: any)[property] ~= value then
		(instance :: any)[property] = value
	end
end

function UIKit.setText(element: TextLabel | TextButton, text: string)
	if element.Text ~= text then
		element.Text = text
	end
end

function UIKit.setTextColor(element: TextLabel | TextButton, color: Color3)
	if element.TextColor3 ~= color then
		element.TextColor3 = color
	end
end

function UIKit.setBackground(element: GuiObject, color: Color3)
	if element.BackgroundColor3 ~= color then
		element.BackgroundColor3 = color
	end
end

function UIKit.setVisible(element: GuiObject, visible: boolean)
	if element.Visible ~= visible then
		element.Visible = visible
	end
end

function UIKit.setSize(element: GuiObject, size: UDim2)
	if element.Size ~= size then
		element.Size = size
	end
end

--[[
	Press-and-hold, which both the work button and the touch drive pad need and
	which neither expressed the same way.
]]
function UIKit.bindHold(element: GuiButton, setter: (boolean) -> ())
	element.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setter(true)
		end
	end)
	element.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			setter(false)
		end
	end)
end

return UIKit
