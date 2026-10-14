
-- check if vehicle is blacklisted
function IsVehicleBlacklisted(vehicle)
	if (#typeBlacklist > 0) then
		local vehicleType = GetVehicleType(vehicle)
		for i = 1, #typeBlacklist do
			if (typeBlacklist[i] == vehicleType) then
				return true
			end
		end
	end

	if (#modelBlacklist > 0) then
		local vehicleModel = GetEntityModel(vehicle)
		for i = 1, #modelBlacklist do
			if (modelBlacklist[i] == vehicleModel) then
				return true
			end
		end
	end

	if (#plateBlacklist > 0) then
		local vehiclePlate = GetVehicleNumberPlateText(vehicle)
		for i = 1, #plateBlacklist do
			if (vehiclePlate:find(plateBlacklist[i]:upper())) then
				return true
			end
		end
	end

	return false
end

local appliedFingerprint = {}

local function fingerprint(points)
	if (type(points) ~= "table" or #points == 0) then return "" end
	local parts = {}
	for i, def in ipairs(points) do
		parts[i] = ("%.2f,%.2f,%.2f:%.2f,%.2f,%.2f"):format(def[1].x, def[1].y, def[1].z, def[2].x, def[2].y, def[2].z)
	end
	return table.concat(parts, ";")
end

function MarkDeformationApplied(vehicle, points)
	appliedFingerprint[vehicle] = fingerprint(points)
end

local function ApplyDeformation(bagName, deformation)
	local vehicle = GetEntityFromStateBagName(bagName)
	local endTime = GetGameTimer() + 5000
	while (not DoesEntityExist(vehicle) and GetGameTimer() < endTime) do
		Wait(100)
		vehicle = GetEntityFromStateBagName(bagName)
	end
	if (not DoesEntityExist(vehicle) or not IsEntityAVehicle(vehicle)) then return end

	local print = fingerprint(deformation)
	if (appliedFingerprint[vehicle] == print) then return end
	appliedFingerprint[vehicle] = print

	if (print ~= "") then
		SetVehicleDeformation(vehicle, deformation)
	else
		SetVehicleDeformationFixed(vehicle)
	end
end

local damageUpdate = {}
local function HandleDeformationUpdate(vehicle)
	if (damageUpdate[vehicle]) then
		damageUpdate[vehicle] = GetGameTimer() + 1000
		return
	end

	damageUpdate[vehicle] = GetGameTimer() + 1000

	while (damageUpdate[vehicle] > GetGameTimer()) do
		Wait(100)
	end

	damageUpdate[vehicle] = nil

	if (not DoesEntityExist(vehicle) or NetworkGetEntityOwner(vehicle) ~= PlayerId()) then return end
	if (IsApplyingDeformation(vehicle)) then return end

	local deformation = GetVehicleDeformation(vehicle)
	if (not deformation or #deformation == 0) then return end

	local print = fingerprint(deformation)
	if (appliedFingerprint[vehicle] == print) then return end
	appliedFingerprint[vehicle] = print

	Entity(vehicle).state:set("deformation", deformation, true)
end

-- state bag handler to apply any deformation
AddStateBagChangeHandler("deformation", nil, function(bagName, key, value, _unused, replicated)
	if (bagName:find("entity") == nil) then return end

	CreateThread(function()
		ApplyDeformation(bagName, value)
	end)
end)

-- update state bag on taking damage
AddEventHandler("gameEventTriggered", function (name, args)
	if (name ~= "CEventNetworkEntityDamage") then return end

	local entity = args[1]
	if (not IsEntityAVehicle(entity) or IsVehicleBlacklisted(entity)) then return end

	if (IsApplyingDeformation(entity)) then return end

	CreateThread(function()
		HandleDeformationUpdate(entity)
	end)
end)

CreateThread(function()
	while (true) do
		Wait(60000)
		for vehicle in pairs(appliedFingerprint) do
			if (not DoesEntityExist(vehicle)) then
				appliedFingerprint[vehicle] = nil
			end
		end
	end
end)

-- fix deformation on vehicle
local function FixVehicleDeformation(vehicle)
	assert(DoesEntityExist(vehicle) and NetworkGetEntityIsNetworked(vehicle), "Parameter \"vehicle\" must be a valid and networked vehicle entity!")

	TriggerServerEvent("VD:fixDeformation", NetworkGetNetworkIdFromEntity(vehicle))
end

exports("FixVehicleDeformation", FixVehicleDeformation)
