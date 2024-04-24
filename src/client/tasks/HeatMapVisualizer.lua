--[[
    File: HeatMapVisualizer.lua
    Author(s): eliphant
    Created: 04/22/2024 @ 17:30:54
    Version: 1.0.0

    Description:
        No description provided.

    Dependencies:
        HeatMapper (server)

    Documentation:
        No documentation provided.
]]

--=> Root
local HeatMapVisualizer = {}

--=> Dependencies
local GetRemote = shared("GetRemote")

--=> Constants
local GRID_SIZE = 10
local PROGRESSIVE_BUILD = false

--=> Local Functions
function getHeatmapColor(count)
	local adjustedCount = math.max(count, 1)
	local logValue = math.log(adjustedCount)
	local scale = 5
	local normalizedValue = (logValue / (math.log(scale) + logValue))
	local r, g, b

	if normalizedValue < 0.5 then
		local midRatio = normalizedValue * 2
		r = 0
		g = 255 * midRatio
		b = 255 * (1 - midRatio)
	else
		local midRatio = (normalizedValue - 0.5) * 2
		r = 255 * midRatio
		g = 255 * (1 - midRatio)
		b = 0
	end

	return math.floor(r), math.floor(g), math.floor(b)
end

--=> Public Functions
function HeatMapVisualizer:CreatePart(position, color)
	local part = Instance.new("Part")
	part.Size = Vector3.new(GRID_SIZE, 1, GRID_SIZE)
	part.Position = Vector3.new(position.X, 1, position.Z)
	part.Transparency = 0.8
    part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.BrickColor = BrickColor.new(color)
	part.Parent = workspace
end

function HeatMapVisualizer:GetData()
	return GetRemote("HeatMapper:GetCompiledData"):InvokeServer()
end

--=> Initializers
function HeatMapVisualizer:Init()
	local compiledData = self:GetData()

	for _, position in compiledData do
		self:CreatePart(Vector3.new(position[1], position[2], position[3]), Color3.fromRGB(255, 0, 0))
	end

	-- local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge

	-- for _, positionTable in pairs(compiledData) do
	-- 	local x, y, z = positionTable[1], positionTable[2], positionTable[3]

	-- 	if x and y and z then
	-- 		minX = math.min(minX, x)
	-- 		maxX = math.max(maxX, x)
	-- 		minZ = math.min(minZ, z)
	-- 		maxZ = math.max(maxZ, z)
	-- 	end
	-- end

	-- minX = math.floor(minX / GRID_SIZE) * GRID_SIZE
	-- maxX = math.ceil(maxX / GRID_SIZE) * GRID_SIZE
	-- minZ = math.floor(minZ / GRID_SIZE) * GRID_SIZE
	-- maxZ = math.ceil(maxZ / GRID_SIZE) * GRID_SIZE

	-- local grid = {}

	-- for x = minX, maxX, GRID_SIZE do
	-- 	for z = minZ, maxZ, GRID_SIZE do
	-- 		grid[x] = grid[x] or {}
	-- 		grid[x][z] = 0
	-- 	end
	-- end

	-- for _, positionTable in compiledData do
	-- 	local x, y, z = positionTable[1], positionTable[2], positionTable[3]

	-- 	if not x or not y or not z then
	-- 		continue
	-- 	end

	-- 	local gridX = math.floor(x / GRID_SIZE) * GRID_SIZE
	-- 	local gridZ = math.floor(z / GRID_SIZE) * GRID_SIZE

	-- 	if not grid[gridX] or not grid[gridX][gridZ] then
	-- 		continue
	-- 	end

	-- 	local cellCount = grid[gridX][gridZ] or 0
	-- 	grid[gridX][gridZ] = cellCount + 1
	-- end

	-- for x, xTable in pairs(grid) do
	-- 	for z, count in pairs(xTable) do
	-- 		self:CreatePart(Vector3.new(x, 0, z), Color3.fromRGB(getHeatmapColor(count)))
	-- 		if PROGRESSIVE_BUILD then
	-- 			task.wait()
	-- 		end
	-- 	end
	-- end
end

--=> Return Job
return HeatMapVisualizer
