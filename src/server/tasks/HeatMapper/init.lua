--[[
    File: HeatMapper.lua
    Author(s): eliphant
    Created: 04/22/2024 @ 16:58:51
    Version: 1.0.0

    Description:
        Provides a heatmap of player positions, updating every UPDATE_RATE seconds.
        Data is stored in a paginated DataStore, with each page containing a list of player positions.

    Dependencies:
        rcall (shared)

    Documentation:
        :GetPlayerPosition(player: Player) => { number, number, number }
            Returns the player's position as a table of X, Y, Z coordinates.
        :GetCompiledData() => { { number, number, number } }
            Returns a compiled list of all player positions from all pages.
        Adding a data handler:
            To add a data handler, create a ModuleScript in the dataHandlers folder.
            The ModuleScript should return a function that takes a player and returns a value.
            The value will be added to the player's position data.
            Example:
            PlayerName.lua
                return function(player)
                    return player.Name
                end
]]

--=> Root
local HeatMapper = {}

--=> Dependencies
local rcall = shared("rcall")
local GetRemote = shared("GetRemote")

--=> Roblox Services
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

--=> Constants
local MAIN_DATA_STORE_PREFIX = "HeatmapPages_2"
local HEATMAP_PAGE_KEY = "HeatmapPageNumber"
local NO_CACHE_OPTION = Instance.new("DataStoreGetOptions")
NO_CACHE_OPTION.UseCache = false
local UPDATE_RATE = 1

--=> Object References
local PageDatastores: { [string]: DataStore } = {}
local PageStore = DataStoreService:GetDataStore("HeatmapPages")
local ExtraDataHandlers: { ModuleScript } = {}

--=> Local Functions
local function getHeatmapStoreNumber(): number
	local pageCount = rcall({
		waitForAPI = {
			"DataStoreService",
			{
				DataStore = HEATMAP_PAGE_KEY,
				RequestType = Enum.DataStoreRequestType.GetAsync,
			},
		},
	}, PageStore.GetAsync, PageStore, HEATMAP_PAGE_KEY) or 1

	return pageCount
end

local function setHeatmapPageNumber(number: number): number
	local pageCount = rcall(
		{
			waitForAPI = {
				"DataStoreService",
				{
					DataStore = MAIN_DATA_STORE_PREFIX,
					RequestType = Enum.DataStoreRequestType.UpdateAsync,
				},
			},
		},
		PageStore.UpdateAsync,
		PageStore,
		HEATMAP_PAGE_KEY,
		function(oldValue)
			if oldValue then
				oldValue = oldValue + 1
			else
				oldValue = 1
			end
			return oldValue
		end
	) or number

	return pageCount
end

local function getHeatmapPageStore(index: number): DataStore
	local storeName = MAIN_DATA_STORE_PREFIX
	if not PageDatastores[storeName] then
		PageDatastores[storeName] = rcall({}, DataStoreService.GetDataStore, DataStoreService, storeName)
	end

	if not index then
		index = 1
	end

	local pageData = rcall({
		waitForAPI = {
			"DataStoreService",
			{
				DataStore = storeName,
				RequestType = Enum.DataStoreRequestType.GetAsync,
			},
		},
	}, PageDatastores[storeName].GetAsync, PageDatastores[storeName], tostring(index)) or {}

	return pageData
end

local function setHeatmapPageStore(index: number, newEntry: number)
	local storeName = MAIN_DATA_STORE_PREFIX
	if not PageDatastores[storeName] then
		PageDatastores[storeName] = rcall({}, DataStoreService.GetDataStore, DataStoreService, storeName)
	end

	if not index then
		index = 1
	end

	rcall(
		{
			waitForAPI = {
				"DataStoreService",
				{
					DataStore = storeName,
					RequestType = Enum.DataStoreRequestType.UpdateAsync,
				},
			},
		},
		PageDatastores[storeName].UpdateAsync,
		PageDatastores[storeName],
		tostring(index),
		function(oldValue)
			if oldValue then
				for _, value in newEntry do
					table.insert(oldValue, value)
				end
			else
				oldValue = { newEntry }
			end
			return oldValue
		end
	)
end

--=> Public Functions
function HeatMapper:GetPlayerPosition(player: Player)
	local character = player.Character

	if not character then
		return
	end

	local primaryPart = character.PrimaryPart

	if not primaryPart then
		return
	end

	return { math.round(primaryPart.Position.X), math.round(primaryPart.Position.Y), math.round(primaryPart.Position.Z) }
end

function HeatMapper:GetCompiledData()
    local fetchedPageCount, lastIndex = pcall(function()
        return getHeatmapStoreNumber()
    end)

    local data = {}

    if fetchedPageCount then
        for i = 1, lastIndex do
            local pageData = getHeatmapPageStore(i) or {}

            for _, entry in ipairs(pageData) do
                table.insert(data, entry)
            end
        end
    end

    return data
end

--=> Initializers
function HeatMapper:Init()
    for _, handler in script.dataHandlers:GetChildren() do
        table.insert(ExtraDataHandlers, require(handler))
    end

	task.spawn(function()
		while task.wait(UPDATE_RATE) do
			local playerPositions = {}

			for _, player in ipairs(Players:GetPlayers()) do
				local position = self:GetPlayerPosition(player)

                for _, handler in ExtraDataHandlers do
                    position[handler.Name] = handler(player)
                end

				if position then
					table.insert(playerPositions, position)
				end
			end

			local fetchedPageCount, lastIndex = pcall(function()
				return getHeatmapStoreNumber()
			end)

			if not lastIndex then
				lastIndex = 1
			end

			if fetchedPageCount then
				local data = getHeatmapPageStore(lastIndex) or {}

				if string.len(HttpService:JSONEncode(data)) > 4000000 then
					lastIndex = setHeatmapPageNumber()
					setHeatmapPageStore(lastIndex, playerPositions)
				else
					setHeatmapPageStore(lastIndex, playerPositions)
				end
			end
		end
	end)

    GetRemote("HeatMapper:GetCompiledData"):OnInvoke(function()
        return self:GetCompiledData()
    end)
end

--=> Return Job
return HeatMapper
