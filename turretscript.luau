-- Discord: emtrazaltaccount | Roblox: emtraz
-- TURRET SYSTEM (server)
-- Every setting lives in ReplicatedStorage.Config.TurretSettings. This script only holds the logic.
--
-- How it works:
--   * Any model with the "Turret" tag becomes a turret. Remove the tag and it gets cleaned up, so
--     you can add or delete turrets while the game is running.
--   * One loop runs every frame. It moves every turret first, then every bullet. One loop for
--     everything is cheaper than one per turret, and new bullets start moving on the same frame.
--   * Bullets don't use Roblox physics. The script moves each bullet itself and casts a ray along
--     the path it travels that frame. That way the server always knows exactly what got hit, and
--     fast bullets can't skip through thin walls.
--   * The server decides who gets shot and how much damage they take. The client only reads the
--     TargetId attribute to draw the HUD.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Settings = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TurretSettings"))

local PARTS = Settings.PartNames
local TARGETING = Settings.Targeting
local BULLETS = Settings.Bullets
local SPIN = Settings.Spin
local LASER = Settings.Laser
local COLORS = Settings.Colors
local SOUNDS = Settings.Sounds

local projectileFolder = workspace:WaitForChild(Settings.Folders.Projectiles)
local turretFolder = workspace:WaitForChild(Settings.Folders.Turrets)

-- Values worked out once at the start, so they aren't worked out again every frame.
--   AIM_TOLERANCE: saved as a cosine so the "am I aimed close enough?" check in update() is one
--     quick dot product instead of working out the real angle.
--   FLAT: removes up/down movement from the target's speed. If the turret tried to lead a jump, it
--     would shoot over the player's head, because they come back down.
--   GRAVITY: bullets drop a little. predictAimPoint uses the same value to aim a bit higher.
--   BULLET_HALF_LENGTH: puts the trail at the two ends of the bullet.
local AIM_TOLERANCE = math.cos(math.rad(TARGETING.AimToleranceDegrees)) -- Stored as a cosine so the check is one dot product
local SWEEP_ANGLE = math.rad(Settings.IdleSweep.AngleDegrees)
local FLAT = TARGETING.IgnoreJumping and Vector3.new(1, 0, 1) or Vector3.one
local GRAVITY = Vector3.new(0, -workspace.Gravity * BULLETS.GravityScale, 0)
local FLASH_TWEEN = TweenInfo.new(Settings.MuzzleEffects.FlashFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BULLET_HALF_LENGTH = BULLETS.Size.Z * 0.5

-- Turn each kind's list of spinning part names into a quick lookup ({ Barrel = true, ... }), so
-- setupSpin can ask "is this a spinning part?" without searching the list every time.
local spinPartSets = {}
for kindName, kind in Settings.Kinds do
	if kind.SpinParts then
		local set = {}
		for _, partName in kind.SpinParts do
			set[partName] = true
		end
		spinPartSets[kindName] = set
	end
end

-- Ray settings are made once and reused, not remade for every shot. Both ignore bullets and turrets,
-- so a bullet can't hit another bullet or the turret that fired it.
-- They're kept separate so the line-of-sight one can be changed later (for example, to see through
-- glass) without changing what bullets hit.
local bulletParams = RaycastParams.new()
bulletParams.FilterType = Enum.RaycastFilterType.Exclude
bulletParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
bulletParams.IgnoreWater = true

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.FilterDescendantsInstances = { projectileFolder, turretFolder }
sightParams.IgnoreWater = true

-- Bullet recycling. Making a new part for every shot and deleting it after is slow, and the
-- Minigun shoots a lot. Used bullets are stored here and reused for the next shot.
local pool = {}
-- Every bullet that's flying right now. It's a plain list so it's quick to loop over.
local activeBullets = {}

-- Builds what a bullet looks like. The part is just for show. The real hit check is the ray in
-- stepBullet, so physics and touching are turned off on it.
local function createBulletPart()
	local part = Instance.new("Part")
	part.Name = "Bullet"
	part.Size = BULLETS.Size
	part.Material = Enum.Material.Neon
	part.Anchored = true -- Moved by raycasts, not physics
	part.CanCollide = false
	part.CanQuery = false -- Rays (like the turret's line of sight) go straight through it
	part.CanTouch = false -- No Touched events. Hits come from the ray instead
	part.CastShadow = false

	-- The trail stretches between these two points, one at the back and one at the front, so the
	-- glow is as long as the bullet and fades out behind it.
	local back = Instance.new("Attachment")
	back.Name = "Back"
	back.Position = Vector3.new(0, 0, BULLET_HALF_LENGTH)
	back.Parent = part
	local front = Instance.new("Attachment")
	front.Name = "Front"
	front.Position = Vector3.new(0, 0, -BULLET_HALF_LENGTH)
	front.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = back
	trail.Attachment1 = front
	trail.LightEmission = 1
	trail.Lifetime = BULLETS.TrailLifetime
	trail.Transparency = NumberSequence.new(0.4, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = part
	return part
end

-- Grab a used bullet from storage if there is one, otherwise make a new one.
local function acquireBullet()
	return table.remove(pool) or createBulletPart() -- Reuse a spare part if there is one
end

-- Puts a finished bullet back in storage. Setting Parent to nil hides it without deleting it.
-- Storage has a size limit, so a big burst of shots doesn't leave hundreds of spare parts lying
-- around. Anything over the limit is deleted.
local function releaseBullet(part)
	part.Trail.Enabled = false -- Otherwise its next shot would draw a line from here to the gun
	part.Parent = nil
	if #pool < BULLETS.PoolSize then
		table.insert(pool, part)
	else
		part:Destroy()
	end
end

-- Sparks, dust and a sound where a bullet hits.
-- All the effects go on one invisible point (an Attachment in Terrain) that faces out from the
-- surface, so the particles spray out of the wall. Deleting that one point later cleans up everything.
local function spawnImpact(position, normal, material, color)
	local effects = Settings.ImpactEffects

	local anchor = Instance.new("Attachment")
	anchor.CFrame = CFrame.lookAt(position + normal * 0.05, position + normal * 2)
	anchor.Parent = workspace.Terrain

	local burst = Instance.new("ParticleEmitter")
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(color)
	burst.LightEmission = 1
	burst.Size = NumberSequence.new(0.25, 0)
	burst.Lifetime = NumberRange.new(0.15, 0.35)
	burst.Speed = NumberRange.new(8, 18)
	burst.SpreadAngle = Vector2.new(60, 60)
	burst.Acceleration = Vector3.new(0, -workspace.Gravity * 0.5, 0)
	burst.EmissionDirection = Enum.NormalId.Front
	burst.Rate = 0 -- One burst instead of a stream
	burst.Parent = anchor

	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	-- Grey dust looks odd on a glowing neon surface, so dust there uses the bullet's colour
	dust.Color = ColorSequence.new(material == Enum.Material.Neon and color or COLORS.ImpactDust)
	dust.Transparency = NumberSequence.new(0.5, 1)
	dust.Size = NumberSequence.new(0.4, 1.6)
	dust.Lifetime = NumberRange.new(0.3, 0.5)
	dust.Speed = NumberRange.new(2, 4)
	dust.SpreadAngle = Vector2.new(30, 30)
	dust.EmissionDirection = Enum.NormalId.Front
	dust.Rate = 0
	dust.Parent = anchor

	local sound = Instance.new("Sound")
	sound.SoundId = SOUNDS.ImpactId
	sound.Volume = SOUNDS.ImpactVolume
	sound.PlaybackSpeed = 0.9 + math.random() * 0.3 -- Small random pitch change so lots of hits don't all sound the same
	sound.RollOffMaxDistance = SOUNDS.ImpactHearingDistance
	sound.Parent = anchor

	burst:Emit(effects.SparkCount)
	dust:Emit(effects.DustCount)
	sound:Play()
	Debris:AddItem(anchor, effects.Lifetime) -- One cleanup for every effect
end

-- Starts a new bullet. The table added to activeBullets holds the bullet's real position and speed,
-- and the part just follows it. Trail:Clear() wipes the old trail from the part's last use, so
-- it doesn't draw a line across the map.
local function fireBullet(origin, velocity, damage, color)
	local part = acquireBullet()
	part.Color = color
	part.Trail.Color = ColorSequence.new(color)
	part.CFrame = CFrame.lookAt(origin, origin + velocity)
	part.Parent = projectileFolder
	part.Trail:Clear()
	part.Trail.Enabled = true

	table.insert(activeBullets, {
		position = origin,
		velocity = velocity,
		damage = damage,
		color = color,
		age = 0,
		part = part,
	})
end

-- If the bullet hit a player, damage them. Then show the hit effect and put the bullet back in storage.
-- Looking for the closest Model above the part that was hit finds the character, even if the
-- bullet hit a hat or other accessory.
local function onBulletHit(bullet, result)
	local character = result.Instance:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		humanoid:TakeDamage(bullet.damage) -- Respects ForceFields
	end
	spawnImpact(result.Position, result.Normal, result.Material, bullet.color)
	releaseBullet(bullet.part)
end

-- Moves one bullet forward by one frame. Returns false when the bullet is done (it hit something
-- or flew too long) so it can be removed.
-- The distance moved uses the average of the speed before and after gravity pulls on it. That keeps
-- the bullet's arc the same whether the game runs at 30 or 240 FPS.
-- The ray covers the whole distance the bullet moves this frame. Only checking where it ends up
-- could miss a wall it flew through in between.
local function stepBullet(bullet, dt)
	local nextVelocity = bullet.velocity + GRAVITY * dt
	local displacement = (bullet.velocity + nextVelocity) * 0.5 * dt

	local result = workspace:Raycast(bullet.position, displacement, bulletParams) -- Stops fast bullets passing through walls
	if result then
		onBulletHit(bullet, result)
		return false
	end

	bullet.position += displacement
	bullet.velocity = nextVelocity
	bullet.age += dt
	if bullet.age >= BULLETS.Lifetime then
		releaseBullet(bullet.part)
		return false
	end

	bullet.part.CFrame = CFrame.lookAt(bullet.position, bullet.position + bullet.velocity)
	return true
end

-- Moves every bullet and removes the finished ones. To remove one, the last bullet in the list is
-- moved into its spot and the end is cut off, which is much faster than shifting the whole list.
-- The loop goes backwards so the bullet moved into the gap has already been moved this frame.
local function updateBullets(dt)
	for i = #activeBullets, 1, -1 do
		if not stepBullet(activeBullets[i], dt) then
			activeBullets[i] = activeBullets[#activeBullets] -- Swap-remove, no shifting
			activeBullets[#activeBullets] = nil
		end
	end
end

-- The Turret class. Each tagged model gets one, holding its parts, stats and where it's aiming.
-- The loop at the bottom of the script calls update() on each one every frame.
local Turret = {}
Turret.__index = Turret

-- Makes sure the model has the parts it needs, then sets up the turret. If something is missing it
-- prints a clear warning and gives up, so one broken model doesn't break the rest of the game.
function Turret.new(model)
	local head = model:FindFirstChild(PARTS.Head)
	local swivel = head and head.PrimaryPart
	local muzzle = swivel and swivel:FindFirstChild(PARTS.Muzzle)
	if not muzzle then
		warn(`[TurretSystem] {model:GetFullName()} is missing {PARTS.Head} / PrimaryPart / {PARTS.Muzzle}`)
		return nil
	end

	local self = setmetatable({}, Turret)
	self.model = model
	self.head = head
	self.swivel = swivel
	self.muzzle = muzzle
	self.flash = swivel:FindFirstChild(PARTS.MuzzleFlash)
	self.eye = head:FindFirstChild(PARTS.Eye)

	-- restCFrame is where the head starts, and the idle sweep swings around it. aimCFrame is where
	-- it's pointing right now. origin is the spot used for range and line-of-sight checks.
	self.restCFrame = head:GetPivot()
	self.aimCFrame = self.restCFrame
	self.origin = self.restCFrame.Position
	self.recoil = 0
	self.lastShot = 0
	-- Random starting values so turrets don't all sweep together, and don't all look for targets
	-- on the same frame.
	self.sweepTime = math.random() * math.pi * 2
	self.scanTimer = math.random() * TARGETING.ScanInterval -- Spreads scans across frames

	-- These run in this order on purpose: readConfig sets the gun sound's pitch, so the sound has
	-- to exist first. setupSpin needs the turret kind from readConfig. setTarget(nil) sets the
	-- starting look (green eye, laser off).
	self:buildEffects()
	self:readConfig()
	self:setupSpin()
	self:setTarget(nil)

	-- If a stat attribute changes (in Studio or from another script), reload the stats right away.
	-- Other attributes are ignored, mostly TargetId, which this script changes itself all the time.
	self.configConnection = model.AttributeChanged:Connect(function(name)
		if Settings.Defaults[name] ~= nil or name == Settings.KindAttribute then
			self:readConfig()
		end
	end)

	return self
end

-- Makes the laser, gun sound and muzzle sparks once, up front. Firing only plays them.
-- The laser is a Beam from the muzzle to laserEnd, a point that update() moves onto the target.
function Turret:buildEffects()
	self.laserEnd = Instance.new("Attachment")
	self.laserEnd.Name = self.model.Name .. "LaserEnd"
	self.laserEnd.Parent = workspace.Terrain -- A point in Terrain uses world position, so it can be placed right on the target

	self.laser = Instance.new("Beam")
	self.laser.Attachment0 = self.muzzle
	self.laser.Attachment1 = self.laserEnd
	self.laser.Color = ColorSequence.new(COLORS.Alert)
	self.laser.Width0 = LASER.Width
	self.laser.Width1 = LASER.Width
	self.laser.LightEmission = 1
	self.laser.Transparency = NumberSequence.new(LASER.Transparency)
	self.laser.FaceCamera = true
	self.laser.Segments = 1
	self.laser.Enabled = false
	self.laser.Parent = self.swivel

	self.fireSound = Instance.new("Sound")
	self.fireSound.SoundId = SOUNDS.FireId
	self.fireSound.Volume = SOUNDS.FireVolume
	self.fireSound.RollOffMaxDistance = SOUNDS.FireHearingDistance
	self.fireSound.Parent = self.swivel

	self.sparks = Instance.new("ParticleEmitter")
	self.sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	self.sparks.Color = ColorSequence.new(COLORS.MuzzleSparks[1], COLORS.MuzzleSparks[2])
	self.sparks.LightEmission = 1
	self.sparks.Size = NumberSequence.new(0.35, 0)
	self.sparks.Lifetime = NumberRange.new(0.08, 0.18)
	self.sparks.Speed = NumberRange.new(14, 24)
	self.sparks.SpreadAngle = Vector2.new(18, 18)
	self.sparks.EmissionDirection = Enum.NormalId.Front
	self.sparks.Rate = 0
	self.sparks.Parent = self.muzzle
end

-- Reads the stats from attributes on the model, or uses Settings.Defaults if one isn't set.
-- It only runs at the start and when a stat changes, so things like fireInterval are worked out
-- here and not every frame.
function Turret:readConfig()
	local model = self.model
	local function get(name)
		local value = model:GetAttribute(name)
		if value == nil then
			return Settings.Defaults[name]
		end
		return value
	end
	self.range = get("Range")
	self.fireInterval = 1 / math.max(get("FireRate"), 0.01) -- Shots per second -> seconds between shots. math.max stops a FireRate of 0 from breaking it
	self.damage = get("Damage")
	self.bulletSpeed = get("BulletSpeed")
	self.turnSpeed = get("TurnSpeed")

	local kindName = model:GetAttribute(Settings.KindAttribute)
	if not Settings.Kinds[kindName] then
		kindName = Settings.DefaultKind -- Unknown kinds fall back to the default
	end
	self.kindName = kindName
	self.style = Settings.Kinds[kindName]
	self.fireSound.PlaybackSpeed = self.style.SoundPitch or 1
end

-- Sets up the spinning barrels for kinds that have SpinParts (the Minigun).
-- Each spinning part's spot on the head is saved once. Every frame the part is put back on that
-- saved spot and then turned, so the barrels stay on the head while it aims and can't slowly
-- drift out of place.
function Turret:setupSpin()
	self.spinParts = nil
	self.spinSpeed = 0
	self.spinAngle = 0
	local names = spinPartSets[self.kindName]
	if not names then
		return
	end
	self.spinParts = {}
	local swivelCFrame = self.swivel.CFrame
	for _, part in self.head:GetChildren() do
		if part:IsA("BasePart") and names[part.Name] then
			self.spinParts[part] = swivelCFrame:ToObjectSpace(part.CFrame) -- Offset from the swivel, rebuilt every frame
		end
	end
	-- The spin centre lines up with the muzzle, so the barrels turn around the line the
	-- bullets come out of.
	local muzzlePosition = self.muzzle.Position
	self.spinAxis = CFrame.new(muzzlePosition.X, muzzlePosition.Y, 0)
end

-- True if nothing is between the turret and the player. The ray stops right at the player, so if it
-- hits nothing the way is clear. Hitting part of the player themselves also counts as seeing them.
function Turret:hasLineOfSight(character, offset)
	local result = workspace:Raycast(self.origin, offset, sightParams)
	return result == nil or result.Instance:IsDescendantOf(character)
end

-- Finds the closest living player in range that the turret can see.
-- The quick distance check runs first, and the line-of-sight ray only runs if it passes. So players
-- who are too far away, or farther than the best one found so far, don't cost a ray.
function Turret:findTarget()
	local bestRoot, bestHumanoid, bestPlayer
	local bestDistance = self.range
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 then
			local offset = root.Position - self.origin
			local distance = offset.Magnitude
			if distance < bestDistance and self:hasLineOfSight(character, offset) then
				bestRoot, bestHumanoid, bestPlayer, bestDistance = root, humanoid, player, distance
			end
		end
	end
	return bestRoot, bestHumanoid, bestPlayer
end

-- Switches to a new target and updates the eye colour and laser. If the target hasn't changed it
-- stops early, so it doesn't keep re-setting the attribute (which gets sent to every player).
-- The HUD uses TargetId to show LOCKED and the arrows.
function Turret:setTarget(root, humanoid, player)
	if root == self.target and root ~= nil then
		return
	end
	self.target, self.targetHumanoid, self.targetPlayer = root, humanoid, player
	self.model:SetAttribute(Settings.TargetAttribute, player and player.UserId or 0) -- The HUD reads this

	local color = root and COLORS.Alert or COLORS.Idle
	self.laser.Enabled = root ~= nil
	if self.eye then
		self.eye.Color = color
		local glow = self.eye:FindFirstChildOfClass("PointLight")
		if glow then
			glow.Color = color
		end
	end
end

-- Aims ahead of a moving player so the bullet lands where they WILL be, not where they are now.
-- How far ahead depends on how long the bullet takes to get there, and that depends on where it's
-- aiming. So it guesses, works out the travel time, guesses again, and repeats a few times.
-- At the end it aims a little higher to make up for the bullet dropping on the way.
function Turret:predictAimPoint(root)
	local origin = self.muzzle.WorldPosition
	local velocity = root.AssemblyLinearVelocity * FLAT
	local point = root.Position
	local travelTime = 0
	for _ = 1, TARGETING.PredictionPasses do
		travelTime = (point - origin).Magnitude / self.bulletSpeed
		point = root.Position + velocity * travelTime
	end
	return point - GRAVITY * 0.5 * travelTime * travelTime -- Aim up to cancel bullet drop
end

-- Can it shoot yet? The cooldown has to be over, and the Minigun's barrels have to be spinning fast
-- enough. The spin-up warns players that bullets are coming.
function Turret:isReadyToFire(now)
	if now - self.lastShot < self.fireInterval then
		return false
	end
	if self.spinParts and self.spinSpeed < SPIN.MaxSpeed * SPIN.FireThreshold then
		return false
	end
	return true
end

-- Shoots one bullet from the muzzle toward the aim point and plays the effects. Recoil is set to
-- full here, and update() slowly brings it back.
function Turret:fire(aimPoint, now)
	local effects = Settings.MuzzleEffects
	self.lastShot = now
	local origin = self.muzzle.WorldPosition
	fireBullet(origin, (aimPoint - origin).Unit * self.bulletSpeed, self.damage, self.style.BulletColor)
	self.recoil = Settings.Recoil.Distance
	self.fireSound:Play()
	self.sparks:Emit(effects.SparkCount)
	if self.flash then
		self.flash.Brightness = effects.FlashBrightness
		TweenService:Create(self.flash, FLASH_TWEEN, { Brightness = 0 }):Play()
	end
end

-- Spins the barrels up when there's a target and down when there isn't. The speed change uses
-- math.exp with dt so it takes the same time at any frame rate. The angle resets after a full
-- turn so the number never gets huge.
function Turret:updateSpin(dt)
	if not self.spinParts then
		return
	end
	local goal = self.target and SPIN.MaxSpeed or 0
	self.spinSpeed += (goal - self.spinSpeed) * (1 - math.exp(-SPIN.Response * dt))
	self.spinAngle = (self.spinAngle + self.spinSpeed * dt) % (math.pi * 2)

	local spin = self.spinAxis * CFrame.Angles(0, 0, self.spinAngle) * self.spinAxis:Inverse() -- Turns around the barrel's centre instead of the swivel's centre
	local swivelCFrame = self.swivel.CFrame
	for part, offset in self.spinParts do
		part.CFrame = swivelCFrame * spin * offset
	end
end

-- Sniper only: the laser gets thicker as the next shot charges, so players can see when it's about
-- to fire and dodge.
function Turret:updateLaser(now)
	if not self.style.ChargeLaser then
		return
	end
	local charge = math.clamp((now - self.lastShot) / self.fireInterval, 0, 1)
	local width = LASER.ChargeMinWidth + (LASER.ChargeMaxWidth - LASER.ChargeMinWidth) * charge
	self.laser.Width0 = width
	self.laser.Width1 = width
end

-- Runs every frame for each turret.
-- Looking for a target is the expensive part, so it only happens every ScanInterval. Turning happens
-- every frame so it still looks smooth. The current target is still checked every frame, so a dead
-- player is dropped right away.
function Turret:update(dt, now)
	self.scanTimer -= dt
	if self.scanTimer <= 0 then
		self.scanTimer = TARGETING.ScanInterval
		self:setTarget(self:findTarget())
	end

	local desired
	local target = self.target
	if target and target.Parent and self.targetHumanoid.Health > 0 then
		local aimPoint = self:predictAimPoint(target)
		desired = CFrame.lookAt(self.origin, aimPoint)
		self.laserEnd.WorldPosition = target.Position
		-- Only shoot when the head is ACTUALLY pointing at the target, not just turning toward it.
		-- A turret that just spotted you has to turn first, which gives you a moment to react.
		local aligned = self.aimCFrame.LookVector:Dot(desired.LookVector) >= AIM_TOLERANCE
		if aligned and self:isReadyToFire(now) then
			self:fire(aimPoint, now)
		end
		self:updateLaser(now)
	else
		if target then
			self:setTarget(nil)
		end
		self.sweepTime += dt
		desired = self.restCFrame * CFrame.Angles(0, math.sin(self.sweepTime * Settings.IdleSweep.Speed) * SWEEP_ANGLE, 0)
	end

	self.aimCFrame = self.aimCFrame:Lerp(desired, 1 - math.exp(-self.turnSpeed * dt)) -- Smooth turning at any frame rate
	-- Recoil fades out the same way at any frame rate. Moving the head along +Z pushes it backwards.
	self.recoil *= math.exp(-Settings.Recoil.Recovery * dt)
	self.head:PivotTo(self.aimCFrame * CFrame.new(0, 0, self.recoil))
	self:updateSpin(dt) -- After the head moves, so the barrels follow it
end

-- Cleans up when the tag is removed or the model is deleted: puts the barrels back, stops listening
-- for attribute changes, and deletes everything buildEffects made. laserEnd is in Terrain, not in
-- the model, so it has to be deleted by hand.
function Turret:destroy()
	self:setTarget(nil)
	self.configConnection:Disconnect()
	if self.spinParts then
		local swivelCFrame = self.swivel.CFrame
		for part, offset in self.spinParts do
			part.CFrame = swivelCFrame * offset
		end
	end
	self.laser:Destroy()
	self.fireSound:Destroy()
	self.sparks:Destroy()
	self.laserEnd:Destroy()
end

-- Every active turret, looked up by its model. That makes it easy to skip a model that's already
-- set up, and to find the right turret when one is removed.
local turrets = {}

local function register(model)
	-- Tagged models that aren't in Workspace (like a spare kept in ServerStorage) shouldn't shoot
	if turrets[model] or not model:IsDescendantOf(workspace) then
		return
	end
	turrets[model] = Turret.new(model)
end

local function unregister(model)
	local turret = turrets[model]
	if turret then
		turret:destroy()
		turrets[model] = nil
	end
end

-- Start listening for new turrets first, then add the ones already there, so none get missed.
-- If one gets added twice, register just skips it.
CollectionService:GetInstanceAddedSignal(Settings.Tag):Connect(register)
CollectionService:GetInstanceRemovedSignal(Settings.Tag):Connect(unregister)
for _, model in CollectionService:GetTagged(Settings.Tag) do
	register(model)
end

-- The one loop that runs every frame. Heartbeat runs after physics, so turrets aim at where players
-- are this frame. The time is read once so every turret uses the same time.
RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for _, turret in turrets do
		turret:update(dt, now)
	end
	updateBullets(dt) -- After turrets fire, so new bullets move this frame
end)
