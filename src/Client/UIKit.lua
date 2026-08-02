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

local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local UIKit = {}

-- Authored against this reference; smaller viewports shrink, larger ones grow
-- a little so 4K text is not hairline-thin. Caps keep phone chrome usable.
UIKit.DesignResolution = Vector2.new(1280, 720)
UIKit.MinScale = 0.55
UIKit.MaxScale = 1.2

UIKit.Theme = {
	Panel = Color3.fromRGB(15, 18, 23),
	PanelTop = Color3.fromRGB(27, 33, 41),
	PanelEdge = Color3.fromRGB(104, 120, 138),
	PanelTransparency = 0.12,
	PanelCorner = 10,

	Text = Color3.fromRGB(235, 235, 235),
	Muted = Color3.fromRGB(170, 178, 190),
	Dim = Color3.fromRGB(140, 148, 160),
	Accent = Color3.fromRGB(255, 210, 110),

	Button = Color3.fromRGB(46, 54, 65),
	ButtonEdge = Color3.fromRGB(128, 142, 158),
	ButtonCorner = 8,
	Track = Color3.fromRGB(31, 37, 45),
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

--[[
	Shrink-to-fit text inside its box instead of painting past the edges.
	Used on every player-facing button and on labels that change length at
	runtime.
]]
function UIKit.fitText(element: TextLabel | TextButton, maxSize: number?, minSize: number?)
	-- Luau's Roblox definitions do not currently expose the shared text
	-- properties through this union even though both classes support them.
	(element :: any).TextScaled = true
	(element :: any).TextWrapped = true
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = maxSize or 16
	constraint.MinTextSize = minSize or 9
	constraint.Parent = element
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = element
	return element
end

function UIKit.horizontalRow(parent: Instance, name: string, height: number): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.ClipsDescendants = true
	row.Size = UDim2.new(1, 0, 0, height)
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.HorizontalFlex = Enum.UIFlexAlignment.Fill
	layout.Parent = row

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = row

	return row
end

--[[
	displayOrder defaults to 10 (run HUD). Debug overlays pass a higher value.
	TextChat / PlayerList live in CoreGui and still draw above any PlayerGui
	order — disable those CoreGui types at the call site if they must not cover
	panels; DisplayOrder alone cannot win that fight.

	No UIScale here. Insets and responsive scale live on separate layers inside
	safeArea — coupling them on one node shifts every Position 0.5 panel.
]]
function UIKit.screen(name: string, parent: Instance, displayOrder: number?): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	-- Full-bleed so the truck camera is not letterboxed; SafeArea below
	-- respects the topbar / home-indicator insets so panels do not collide.
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = displayOrder or 10
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		(gui :: any).ClipToDeviceSafeArea = true
	end)
	gui.Parent = parent
	return gui
end

--[[
	Panel parent for player-facing HUD.

	InsetRoot uses Position/Size for GuiInset (no UIPadding). ScaleHost holds
	UIScale + inverse Size so scale never shares a node with insets — that
	pairing was shifting centered Brief/Result/Toast off the viewport midline.
]]
function UIKit.safeArea(parent: Instance): Frame
	local insetRoot = Instance.new("Frame")
	insetRoot.Name = "InsetRoot"
	insetRoot.BackgroundTransparency = 1
	insetRoot.BorderSizePixel = 0
	insetRoot.Size = UDim2.fromScale(1, 1)
	insetRoot.Parent = parent

	local scaleHost = Instance.new("Frame")
	scaleHost.Name = "SafeArea"
	scaleHost.BackgroundTransparency = 1
	scaleHost.BorderSizePixel = 0
	scaleHost.Size = UDim2.fromScale(1, 1)
	scaleHost.Parent = insetRoot

	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = scaleHost

	local function applyInset()
		local inset = GuiService:GetGuiInset()
		local top = inset.Y + 8
		local bottom = math.max(8, inset.Y * 0.35)
		local left = 8
		local right = 8
		insetRoot.Position = UDim2.fromOffset(left, top)
		insetRoot.Size = UDim2.new(1, -(left + right), 1, -(top + bottom))
	end

	applyInset()
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(applyInset)
	end)
	UIKit.bindResponsiveScale(scaleHost)
	return scaleHost
end

--[[
	host is the ScaleHost Frame that owns ResponsiveScale. Keeps inverse Size
	in lockstep with Scale so the host still fills InsetRoot after UIScale.
]]
function UIKit.bindResponsiveScale(host: GuiObject)
	local scale = host:FindFirstChild("ResponsiveScale")
	if not scale or not scale:IsA("UIScale") then
		return
	end

	local function refresh()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local size = camera.ViewportSize
		local design = UIKit.DesignResolution
		local factor = math.min(size.X / design.X, size.Y / design.Y)
		local clamped = math.clamp(factor, UIKit.MinScale, UIKit.MaxScale)
		scale.Scale = clamped
		host.Size = UDim2.fromScale(1 / clamped, 1 / clamped)
	end

	local viewportConnection: RBXScriptConnection? = nil
	local function bindCamera(camera: Camera?)
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
		end
		refresh()
	end

	bindCamera(Workspace.CurrentCamera)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bindCamera(Workspace.CurrentCamera)
	end)
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
	frame.ClipsDescendants = true
	apply(frame, props)
	UIKit.corner(frame, props and props.CornerRadius or Theme.PanelCorner)

	local stroke = Instance.new("UIStroke")
	stroke.Name = "PanelEdge"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Theme.PanelEdge
	stroke.Thickness = 1
	stroke.Transparency = 0.55
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Name = "PanelShade"
	gradient.Color = ColorSequence.new(Theme.PanelTop, Theme.Panel)
	gradient.Rotation = 90
	gradient.Parent = frame
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
	-- Gamepad GUI navigation steals the D-pad otherwise, which is how
	-- strappers cycle stations on a controller.
	element.Selectable = false
	element.Font = Enum.Font.GothamBold
	element.TextSize = 16
	element.TextColor3 = Color3.fromRGB(240, 240, 240)
	element.Text = ""
	element.ClipsDescendants = true
	apply(element, props)
	UIKit.corner(element, props and props.CornerRadius or Theme.ButtonCorner)
	local stroke = Instance.new("UIStroke")
	stroke.Name = "ButtonEdge"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = Theme.ButtonEdge
	stroke.Thickness = 1
	stroke.Transparency = 0.68
	stroke.Parent = element
	UIKit.fitText(element, props and props.MaxTextSize or 15, 9)
	return element
end

-- ------------------------------------------------------- guarded setters

function UIKit.set(instance: Instance, property: string, value: any)
	if (instance :: any)[property] ~= value then
		(instance :: any)[property] = value
	end
end

-- Luau reads a property off a union happily but refuses to write one, so the
-- two text setters below cast on assignment. The read side stays typed, which
-- is where a wrong element type would actually show up.
export type TextElement = TextLabel | TextButton

function UIKit.setText(element: TextElement, text: string)
	if element.Text ~= text then
		(element :: any).Text = text
	end
end

function UIKit.setTextColor(element: TextElement, color: Color3)
	if element.TextColor3 ~= color then
		(element :: any).TextColor3 = color
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

function UIKit.setActive(element: GuiButton, active: boolean)
	if element.Active ~= active then
		element.Active = active
	end
	if element.AutoButtonColor ~= active then
		element.AutoButtonColor = active
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
