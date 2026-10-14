
-- the minimum damage value at a deformation point before being registered as actual damage
local DEFORMATION_DAMAGE_THRESHOLD <const> = 0.05

-- max difference for angle to be considered to steep (0.0-1.0)
local ANGLE_THRESHOLD <const> = 0.5

-- iterations for damage application
local MAX_PASSES <const> = 12
local PASS_DELAY_MS <const> = 150

local START_DELTA <const> = 0.3
local DELTA_STEP <const> = 0.15
local MAX_DELTA <const> = 1.2

local HEALTH_DAMAGE <const> = 1.0

local POINTS_PER_FRAME <const> = 12

local APPLY_DISTANCE <const> = 150.0
local MAX_CONCURRENT <const> = 4

local COLLISION_TIMEOUT <const> = 5000

local APPLY_GRACE_MS <const> = 1500

local applying = {}
local activeApplies = 0

-- cache for deformation offsets
local deformationOffsets = {}

local math_floor, table_insert, table_remove = math.floor, table.insert, table.remove

-- gets deformation from a vehicle
function GetVehicleDeformation(vehicle)
	assert(vehicle ~= nil and DoesEntityExist(vehicle), "Parameter \"vehicle\" must be a valid vehicle entity!")

	local offsets = GetVehicleOffsetsForDeformation(vehicle)

	-- get deformation from vehicle
	local deformationPoints = {}
	for i = 1, #offsets do
		local projectedDamageVector = ClampVectorAlongAxis(GetVehicleDeformationAtPos(vehicle, offsets[i].x, offsets[i].y, offsets[i].z), -offsets[i])
		if (#(projectedDamageVector) > DEFORMATION_DAMAGE_THRESHOLD) then
			deformationPoints[#deformationPoints + 1] = { offsets[i], projectedDamageVector }
		end
	end

	LogDebug("Got %s deformation point(s) from \"%s\".", #deformationPoints, GetVehicleNumberPlateText(vehicle))

	return deformationPoints
end

local function applyPasses(vehicle, deformationPoints, superseded)
	local mass = GetVehicleHandlingFloat(vehicle, "CHandlingData", "fMass")
	local deformMult = GetVehicleHandlingFloat(vehicle, "CHandlingData", "fDeformationDamageMult")
	if (mass <= 0.0 or deformMult <= 0.00001) then
		LogDebug("\"%s\" cannot be deformed (fDeformationDamageMult %.3f).", GetVehicleNumberPlateText(vehicle), deformMult)
		return 0
	end
	local impulsePerDelta = mass / deformMult

	local delta = {}
	local passes = 0
	local pending = true
	while (pending and passes < MAX_PASSES) do
		if (superseded()) then return passes end

		pending = false
		local calls = 0

		for i, def in ipairs(deformationPoints) do
			local offset = vector3(def[1].x, def[1].y, def[1].z)
			local current = ClampVectorAlongAxis(GetVehicleDeformationAtPos(vehicle, offset.x, offset.y, offset.z), -offset)
			if (#current < #vector3(def[2].x, def[2].y, def[2].z) and (delta[i] or 0.0) < MAX_DELTA) then
				delta[i] = delta[i] and math.min(delta[i] + DELTA_STEP, MAX_DELTA) or START_DELTA
				SetVehicleDamage(vehicle, offset.x, offset.y, offset.z, HEALTH_DAMAGE, delta[i] * impulsePerDelta, true)
				pending = true

				calls = calls + 1
				if (calls % POINTS_PER_FRAME == 0) then
					Wait(0)
					if (superseded()) then return passes end
				end
			end
		end

		passes = passes + 1
		Wait(PASS_DELAY_MS)
	end

	return passes
end

-- sets deformation on a vehicle
function SetVehicleDeformation(vehicle, deformationPoints, callback)
	assert(vehicle ~= nil and DoesEntityExist(vehicle), "Parameter \"vehicle\" must be a valid vehicle entity!")
	assert(deformationPoints ~= nil and type(deformationPoints) == "table", "Parameter \"deformationPoints\" must be a table!")

	-- ignore if deformation is already worse
	-- TODO: BROKEN AS OF NOW
	--if (not IsDeformationWorse(deformationPoints, GetVehicleDeformation(vehicle))) then return end

	if (deformationPoints[1] and type(deformationPoints[1][2]) == "number") then
		LogDebug("Got pre v2.2.0 data, ignoring function call...")
		return
	end

	local token = {}
	applying[vehicle] = token

	CreateThread(function()
		local function superseded()
			return not DoesEntityExist(vehicle) or applying[vehicle] ~= token
		end

		local function release()
			if (applying[vehicle] == token) then
				applying[vehicle] = nil
			end
		end

		while (not superseded() and #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(vehicle)) > APPLY_DISTANCE) do
			Wait(1000)
		end

		while (not superseded() and activeApplies >= MAX_CONCURRENT) do
			Wait(100)
		end
		if (superseded()) then return release() end
		activeApplies = activeApplies + 1

		local deadline = GetGameTimer() + COLLISION_TIMEOUT
		while (not superseded() and not HasCollisionLoadedAroundEntity(vehicle) and GetGameTimer() < deadline) do
			Wait(100)
		end

		local passes = 0
		if (not superseded()) then
			local engineHealth = GetVehicleEngineHealth(vehicle)
			local bodyHealth = GetVehicleBodyHealth(vehicle)
			local tankHealth = GetVehiclePetrolTankHealth(vehicle)

			local froze = false
			if (not IsEntityPositionFrozen(vehicle)
				and GetPedInVehicleSeat(vehicle, -1) == 0
				and GetEntitySpeed(vehicle) < 1.0) then
				FreezeEntityPosition(vehicle, true)
				froze = true
			end

			passes = applyPasses(vehicle, deformationPoints, superseded)

			if (DoesEntityExist(vehicle)) then
				SetVehicleEngineHealth(vehicle, math.max(GetVehicleEngineHealth(vehicle), engineHealth))
				SetVehicleBodyHealth(vehicle, math.max(GetVehicleBodyHealth(vehicle), bodyHealth))
				SetVehiclePetrolTankHealth(vehicle, math.max(GetVehiclePetrolTankHealth(vehicle), tankHealth))

				if (froze) then
					FreezeEntityPosition(vehicle, false)
				end
			end
		end

		activeApplies = activeApplies - 1

		if (superseded()) then return release() end

		if (NetworkGetEntityOwner(vehicle) == PlayerId() and not IsVehicleBlacklisted(vehicle)) then
			local state = Entity(vehicle).state
			if (state.deformation == nil) then
				MarkDeformationApplied(vehicle, deformationPoints)
				state:set("deformation", deformationPoints, true)
			end
		end

		LogDebug("Applying deformation finished for \"%s\" in %s passes.", GetVehicleNumberPlateText(vehicle), passes)

		Wait(APPLY_GRACE_MS)
		release()

		if (callback) then
			callback()
		end
	end)
end

function IsApplyingDeformation(vehicle)
	return applying[vehicle] ~= nil
end

-- returns true if deformation is worse
-- TODO: BROKEN AS OF NOW
function IsDeformationWorse(newDef, oldDef)
	assert(newDef ~= nil and type(newDef) == "table", "Parameter \"newDeformation\" must be a table!")
	assert(oldDef == nil or type(oldDef) == "table", "Parameter \"oldDeformation\" must be nil or a table!")

	if (oldDef == nil or #newDef > #oldDef) then
		return true
	elseif (#newDef < #oldDef) then
		return false
	end

	for i, new in ipairs(newDef) do
		local found = false
		for j, old in ipairs(oldDef) do
			if (#new[1] == #old[1]) then
				found = true

				if (#new[2] > #old[2]) then
					return true
				end
			end
		end

		if (not found) then
			return true
		end
	end

	return false
end

-- returns true if deformation is equal
-- TODO: PROBABLY BROKEN AS WELL
function IsDeformationEqual(newDef, oldDef)
	assert(newDef == nil or type(newDef) == "table", "Parameter \"newDeformation\" must be nil or a table!")
	assert(oldDef == nil or type(oldDef) == "table", "Parameter \"oldDeformation\" must be nil or a table!")

	if (oldDef == nil and newDef == nil) then
		return true
	end
	if (oldDef == nil or newDef == nil or #newDef ~= #oldDef) then
		return false
	end

	for i, def in ipairs(newDef) do
		if (#def[2] ~= #oldDef[i][2]) then
			return false
		end
	end

	return true
end

-- returns offsets for deformation check
function GetVehicleOffsetsForDeformation(vehicle)
	local model = GetEntityModel(vehicle)

	if (deformationOffsets[model]) then
		return deformationOffsets[model]
	end

	local pos = GetEntityCoords(PlayerPedId()) + vector3(0, 0, -50)
	local newVehicle = CreateVehicle(model, pos.x, pos.y, pos.z, 0.0, false, false)
	FreezeEntityPosition(newVehicle, true)
	SetEntityAlpha(newVehicle, 0)

	local min, max = GetModelDimensions(model)

	local defPoints = {}

	local count = 0
	for x = -1, 1, 0.25 do
		for y = 1, -1, -0.25 do
			for z = -1, 1, 0.5 do
				if ((y < -0.55 or y > 0.55) and z > -0.6) then
					count += 1

					defPoints[count] = vector3(
						(max.x - min.x) * x * 0.5 + (max.x + min.x) * 0.5,
						(max.y - min.y) * y * 0.5 + (max.y + min.y) * 0.5,
						(max.z - min.z) * z * 0.5 + (max.z + min.z) * 0.5
					)
				end
			end
		end
	end

	for i = #defPoints, 1, -1 do
		if (IsPointTooFarFromVehicle(defPoints[i], newVehicle)) then
			table_remove(defPoints, i)
		end
	end

	DeleteEntity(newVehicle)

	deformationOffsets[model] = defPoints

	return defPoints
end

-- checks if a point is too far from the vehicle or the angle too steep
function IsPointTooFarFromVehicle(point, vehicle)
	local vehPos = GetEntityCoords(vehicle)
	local pointInWorld = GetOffsetFromEntityInWorldCoords(vehicle, point.x, point.y, point.z)
	local _, hit, position, normal, hitEntity = GetShapeTestResult(
		StartExpensiveSynchronousShapeTestLosProbe(pointInWorld.x, pointInWorld.y, pointInWorld.z, vehPos.x, vehPos.y, vehPos.z, 2, 0, 0)
	)

	if (not hit or hitEntity ~= vehicle) then
		return true
	end

	-- return angle difference > threshold
	return 1.0 - dot(norm(pointInWorld - position), norm(normal)) > ANGLE_THRESHOLD
end

-- clamps a vector on an an arbitrary axis
function ClampVectorAlongAxis(v, axis)
	local axisNorm = norm(axis)

	return dot(v, axisNorm) * axisNorm
end

-- rounds a float to the given number of decimals
function Round(value, numDecimals)
	return math_floor(value * 10^numDecimals) / 10^numDecimals
end

function LogDebug(text, ...)
	if (debugMode) then
		print(("^0[DEBUG] %s^0"):format(text):format(...))
	end
end

exports("GetVehicleDeformation", GetVehicleDeformation)
exports("SetVehicleDeformation", SetVehicleDeformation)
exports("IsDeformationWorse", IsDeformationWorse)
exports("IsDeformationEqual", IsDeformationEqual)
exports("GetDeformationOffsets", GetVehicleOffsetsForDeformation)
