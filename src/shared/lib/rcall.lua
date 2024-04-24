--[[ File Info

	Authors: ChiefWildin, Stratiz, FriendlyBiscuit
	Module: rcall.lua
	Created: 04/15/2023
	Version: 1.2.1

	Retrying call. Provides a way to call functions with a retry limit and
	delay to protect against calls that fail occasionally, such as web API
	calls.

--]]

--[[ API

	rcall(params: rcallParams, callback: (...any) -> ...any, ...: any): ...any
		Repeatedly calls the provided `callback` function until successful. Any
		parameters provided after `callback` will be passed to it. Will return
		the results of `callback` if successful, unless it is run asynchronously.

		`params` is a table with the following optional fields:
		```lua
		{
			async: boolean, -- Whether to run the callback asynchronously. Defaults to false.
			failWarning: string, -- A custom warning to print with the system-provided warning if the callback fails.
			retryDelay: number, -- The number of seconds to wait between retries. Defaults to 2.
			retryLimit: number, -- The number of times to retry the callback before giving up. If not provided, retries infinitely.
			requireResult: boolean, -- Whether the callback must return a result to be considered successful. Defaults to false.
			silent: boolean, -- Whether the error warning should be silent. Defaults to false.
			traceback: boolean, -- Whether the error warning should include a traceback. Defaults to false.
			waitForAPI: {string, {}} -- The API name and any parameters to wait for before running the callback. (server only)
		}
		```

		`waitForAPI` currently supports the following services/parameters:
		```lua
		{
			"HttpService", {},
			"MessagingService", {},
			"MemoryStoreService", {},
			"DataStoreService", {
				DataStore: string, -- The name of the DataStore to wait for before running the callback.
				RequestType: Enum.DataStoreRequestType, -- The type of request to wait for before running the callback.
			},
		}
		```

		Example:
		```lua
			rcall({retryLimit = 3}, myFunction, "hello", "world")
		```
--]]

-- Services

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

-- Types

type rcallParams = {
	async: boolean,
	failWarning: string,
	retryDelay: number,
	retryLimit: number,
	requireResult: boolean,
	silent: boolean,
	traceback: boolean,
	waitForAPI: { string | {} },
}

-- Constants

local IS_SERVER = RunService:IsServer()
-- An artificial buffer to give us some extra padding on the request budget
local DATASTORE_BUFFER_SIZE = 3
-- Whether we should force rcall to print a stack trace for debugging
local FORCE_TRACEBACK = false
-- Real HTTP request limit is 500 per minute, but we knock a few off because
-- there are still requests that slip through the cracks (not wrapped in rcall)
local HTTP_REQUESTS_PER_MINUTE = 450
local VERBOSE_OUTPUT = false

-- Global Variables

local CurrentPlayerCount = 0
local HttpRequestBudget = HTTP_REQUESTS_PER_MINUTE
local HttpWarningSent = false
local LastApiCallCache = {}
local Queues: {[string]: {}} = {}
local QueueProcessingStates: {[string]: boolean} = {}

-- Private Functions

local function vprint(...)
	if VERBOSE_OUTPUT then
		print(...)
	end
end

local RateLimits = {
	MemoryStoreService = function(currentTime, _)
		local lastCallTickDelta = currentTime - (LastApiCallCache["MemoryStoreService"] or 0)

		local rateLimit = 1
		if CurrentPlayerCount > 0 then
			rateLimit = 60 / (CurrentPlayerCount * 100)
		end

		local canCall = lastCallTickDelta > rateLimit
		if canCall then
			LastApiCallCache["MemoryStoreService"] = currentTime
		end

		return canCall
	end,
	DataStoreService = function(_, params)
		local requestType = params.RequestType or Enum.DataStoreRequestType.GetAsync

		local budget = DataStoreService:GetRequestBudgetForRequestType(requestType)
		if budget <= DATASTORE_BUFFER_SIZE then
			return false
		end

		return true
	end,
	HttpService = function(_, params)
		HttpRequestBudget -= params.RequestCount or 1

		if HttpRequestBudget < 0 then
			if not HttpWarningSent then
				warn("[rcall] HTTP OVER BUDGET")
				HttpWarningSent = true
			end

			return false
		end

		return true
	end,
	MessagingService = function(currentTime, _)
		local lastCallTickDelta = currentTime - (LastApiCallCache["MessagingService"] or 0)

		local canCall = lastCallTickDelta > 60 / (150 + 60 * CurrentPlayerCount)
		if canCall then
			LastApiCallCache["MessagingService"] = currentTime
		end

		return canCall
	end,
}

local function GetQueue(queueLabel: string)
	if not Queues[queueLabel] then
		Queues[queueLabel] = {}
	end

	return Queues[queueLabel]
end

local function ProcessCallbackQueue(queueLabel)
	if QueueProcessingStates[queueLabel] then
		return
	end

	QueueProcessingStates[queueLabel] = true

	local queue = GetQueue(queueLabel)

	task.spawn(function()
		while queue[1] do
			local data = queue[1]
			if RateLimits[data.ServiceName](os.clock(), data.Params) then
				data.Approved = true
				table.remove(queue, 1)
			else
				task.wait()
			end
		end
		QueueProcessingStates[queueLabel] = false
	end)
end

local function AddToCallbackQueue(apiParams: {[string]: {}})
	local requiredApi = apiParams[1]

	local data = {
		Approved = false,
		Params = apiParams[2] or {},
		ServiceName = requiredApi,
	}
	local queueLabel = requiredApi
	if requiredApi == "DataStoreService" then
		queueLabel = apiParams[2].RequestType.Name
	end
	table.insert(GetQueue(queueLabel), data)

	-- Kick off the queue processing if not already started
	ProcessCallbackQueue(queueLabel)

	-- Wait for the signal to be fired, telling us the service is ready
	-- DO NOT RELY ON ROBLOX EVENTS FOR THIS. KEEP IN A SYNCHRONOUS THREAD OR
	-- YOU WILL BE PRONE TO DROPPING THE SIGNAL. THAT LITTLE BIT OF INFO COST ME
	-- 5 HOURS.
	while not data.Approved do
		task.wait()
	end
end

local function MainLoop(params: rcallParams, callback, ...)
	local retryDelay = params.retryDelay or 2
	local retryLimit = params.retryLimit
	local customMessage = params.failWarning

	local success, result
	local retries = 0
	while not success or (params.requireResult and not result) do
		if retryLimit and retries >= retryLimit then
			return
		end

		if params.waitForAPI and IS_SERVER then
			local requiredApi = params.waitForAPI[1]
			if RateLimits[requiredApi] then
				AddToCallbackQueue(params.waitForAPI)
			else
				warn(
					"Unsupported API '"
						.. tostring(requiredApi)
						.. "' provided to rcall, proceeding without waiting.\n"
						.. debug.traceback()
				)
			end
		end

		local callResults = table.pack(pcall(callback, ...))
		success = table.remove(callResults, 1)
		result = callResults[1]

		if not success or (params.requireResult and not result) then
			if not params.silent then
				if customMessage then
					warn(customMessage)
				end
				-- result might be nil if requiring result, so convert to string
				local errorMessage = tostring(result)
				if params.traceback or FORCE_TRACEBACK then
					errorMessage ..= "\n" .. debug.traceback()
				end
				warn("[rcall] Failed attempt, params:", params, "error:", errorMessage)
			end

			retries += 1
			if retryLimit and retries == retryLimit then
				return
			end

			task.wait(retryDelay)
		else
			return table.unpack(callResults)
		end
	end
end

-- Main Function

--[[
	Repeatedly calls the provided `callback` function until successful. Any
	parameters provided after `callback` will be passed to it. Will return the
	results of `callback` if successful, unless it is run asynchronously.

	---

	`params` is a table with the following optional fields:
	```lua
	{
	    async: boolean, -- Whether to run the callback asynchronously. Defaults to false.
		failWarning: string, -- A custom warning to print with the system-provided warning if the callback fails.
		retryDelay: number, -- The number of seconds to wait between retries. Defaults to 2.
		retryLimit: number, -- The number of times to retry the callback before giving up. If not provided, retries infinitely.
	    requireResult: boolean, -- Whether the callback must return a result to be considered successful. Defaults to false.
		silent: boolean, -- Whether the error warning should be silent. Defaults to false.
		traceback: boolean, -- Whether the error warning should include a traceback. Defaults to false.
	    waitForAPI: {string, {}} -- The API name and any parameters to wait for before running the callback. (server only)
	}
	```
	`waitForAPI` currently supports the following services/parameters:
		```lua
		{
			"HttpService", {},
			"MessagingService", {},
			"MemoryStoreService", {},
			"DataStoreService", {
				DataStore: string, -- The name of the DataStore to wait for before running the callback.
				RequestType: Enum.DataStoreRequestType, -- The type of request to wait for before running the callback.
			},
		}
		```

	---

	Example:
	```lua
		rcall({retryLimit = 3}, myFunction, "hello", "world")
	```
]]
local rcall = function(params: rcallParams, callback: (...any) -> ...any, ...: any): ...any
	local async = params.async or false

	if async then
		task.spawn(MainLoop, params, callback, ...)
	else
		return MainLoop(params, callback, ...)
	end
end

do
	if not IS_SERVER then
		return rcall
	end

	-- Handle player count changes
	Players.PlayerAdded:Connect(function()
		CurrentPlayerCount += 1
	end)
	Players.PlayerRemoving:Connect(function()
		CurrentPlayerCount -= 1
	end)
	CurrentPlayerCount = #Players:GetPlayers()

	task.spawn(function()
		while task.wait(60) do
			vprint("Resetting HTTP request budget. Requests used in the last minute:", HTTP_REQUESTS_PER_MINUTE - HttpRequestBudget)
			HttpRequestBudget = HTTP_REQUESTS_PER_MINUTE
			HttpWarningSent = false
		end
	end)

	-- Make sure the callback queue empties before the game closes
	game:BindToClose(function()
		-- Initialize to true just to enter the loop
		local queueIsProcessing = true
		while queueIsProcessing do
			queueIsProcessing = false
			for _, queue in pairs(Queues) do
				if #queue > 0 then
					queueIsProcessing = true
					break
				end
			end
			task.wait()
		end
	end)
end

return rcall
