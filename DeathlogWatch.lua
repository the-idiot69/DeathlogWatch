--[[
DeathlogWatch — passive monitor for the Deathlog / DeathNotificationLib
death-alert channel.

Copyright (C) 2026 DeathlogWatch contributors

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 3 of the License, or (at your
option) any later version.  See the LICENSE file for the full text.

Deathlog death reports are plain chat messages on a hidden, password-
protected channel ("hcdeathalertschannel").  The channel carries the
report payload but the receiving addon throws the *sender* away before
the death is written to the database, so a forged report is
indistinguishable from a real one once it lands.

This addon joins the same channel read-only and records, for every
report it sees:  who sent it, whose death it claims, and whether anyone
else independently corroborated it.  It never transmits anything.

  /dlwatch            summary of the most suspicious senders
  /dlwatch sender X   every report broadcast by X
  /dlwatch victim X   every report claiming X died, and who sent them
  /dlwatch recent     last 40 reports seen
  /dlwatch export     copy-pasteable dump of the current report
  /dlwatch clear      wipe collected data
--]]

local ADDON_NAME = ...

---------------------------------------------------------------------------
-- Wire protocol (mirrors DeathNotificationLib~Protocol.lua)
---------------------------------------------------------------------------

local CHANNEL_BASE = "hcdeathalertschannel"
local CHANNEL_PW = CHANNEL_BASE .. "pw"

local DELIM_CMD = "$"
local DELIM_FIELD = "~"

local CMD_DEATH_PING = "1"
local CMD_CHECKSUM = "2"

--- Keep the event log bounded so SavedVariables stays a sane size.
local MAX_EVENTS = 6000
--- Lines printed per chat listing, before truncating.  Kept small because
--- the chat frame only holds a handful of visible lines.
local DEFAULT_LINES = 20
local MAX_LINES = 100
--- Drop tracked checksums older than this (seconds).
local CHECKSUM_TTL = 3600

--- Reverse of DeathNotificationLib's escapeField().
local function unescapeField(s)
	if s == nil or s == "" then
		return s
	end
	return (s:gsub("%%%%", "\1"):gsub("%%s", ";"):gsub("%%b", "\\"):gsub("%%p", "|"):gsub("%%t", "~"):gsub("\1", "%%"))
end

--- Decode a v3 death-ping payload into its fields.  Returns nil if the
--- payload is not v3-shaped (legacy v2 messages, or garbage).
local function decodeMessage(msg)
	local values = {}
	for w in msg:gmatch("(.-)~") do
		values[#values + 1] = w
	end
	if #values < 14 then
		return nil
	end

	local guild = unescapeField(values[2])
	if guild == "" then
		guild = nil
	end

	return {
		name = unescapeField(values[1]) or "",
		guild = guild,
		source_id = tonumber(values[3]),
		race_id = tonumber(values[4]),
		class_id = tonumber(values[5]),
		level = tonumber(values[6]),
		instance_id = tonumber(values[7]),
		map_id = tonumber(values[8]),
		played = tonumber(values[10]),
		last_words = unescapeField(values[11]),
		date = tonumber(values[12]),
		version = tonumber(values[14]) or 3,
	}
end

--- Same checksum the library uses to correlate a report with the
--- corroborations other clients send for it.
local function fletcher16(pd)
	local level = pd.level or 0
	if pd.source_id == -1 then
		level = 0
	end
	local data = pd.name .. ":" .. (pd.guild or "") .. ":" .. level
	local sum1, sum2 = 0, 0
	for i = 1, #data do
		sum1 = (sum1 + data:byte(i)) % 255
		sum2 = (sum2 + sum1) % 255
	end
	return pd.name .. "-" .. bit.bor(bit.lshift(sum2, 8), sum1)
end

local function shortName(full)
	if not full then
		return "?"
	end
	return (full:match("^([^-]+)")) or full
end

---------------------------------------------------------------------------
-- Name matching
--
-- Character names on EU realms routinely contain accented letters, and
-- WoW's string.lower() is a byte-wise, locale-dependent call that does not
-- understand UTF-8 — in a Latin-1 locale it will happily rewrite the lead
-- byte of a multibyte sequence and corrupt the name.  Everything here
-- lowercases ASCII only, so multibyte characters pass through untouched.
---------------------------------------------------------------------------

local function asciiLower(s)
	return (s:gsub("[A-Z]", function(c)
		return string.char(c:byte() + 32)
	end))
end

--- Length of a UTF-8 string in characters rather than bytes.  Continuation
--- bytes (0x80-0xBF) belong to the character before them.
local function utf8len(s)
	local _, n = tostring(s):gsub("[^\128-\191]", "")
	return n
end

--- Left-align to `width` display characters.
---
--- string.format("%-16s") pads by BYTE length, so a name containing an
--- accent ("Zejá" — 5 bytes, 4 characters) lands one column short and
--- drags every column after it out of line.  Padding by character count
--- keeps the table square.
---
--- Assumes one character is one cell, which holds for Latin names; CJK
--- names are double-width and would still skew.
local function padRight(s, width)
	s = tostring(s)
	local pad = width - utf8len(s)
	if pad > 0 then
		return s .. string.rep(" ", pad)
	end
	return s
end

--- Accented Latin letters folded to their ASCII base, so someone typing
--- "Zeja" still finds "Zejá" (and vice versa).
local ACCENT_FOLD = {}
do
	local groups = {
		a = "àáâãäåÀÁÂÃÄÅ",
		e = "èéêëÈÉÊË",
		i = "ìíîïÌÍÎÏ",
		o = "òóôõöøÒÓÔÕÖØ",
		u = "ùúûüÙÚÛÜ",
		y = "ýÿÝ",
		n = "ñÑ",
		c = "çÇ",
		s = "ß",
	}
	for base, chars in pairs(groups) do
		for ch in chars:gmatch("[\194-\244][\128-\191]*") do
			ACCENT_FOLD[ch] = base
		end
	end
end

local function foldAccents(s)
	return (s:gsub("[\194-\244][\128-\191]*", function(ch)
		return ACCENT_FOLD[ch] or ch
	end))
end

--- Canonical form used for all name comparisons.
local function normName(s)
	return foldAccents(asciiLower(s or ""))
end

--- Resolve a user-typed name against a set of recorded names.
--- Returns the matched name, plus a list of near-misses when there is no
--- clean hit — so "not found" can be distinguished from "you typed it
--- slightly differently".
---@param query string
---@param names table<string, boolean>  set of candidate names
---@return string|nil matched
---@return string[] candidates
local function resolveName(query, names)
	if names[query] then
		return query, {}
	end

	local q = normName(query)
	local exact, partial = {}, {}
	for name in pairs(names) do
		local n = normName(name)
		if n == q then
			exact[#exact + 1] = name
		elseif q ~= "" and n:find(q, 1, true) then
			partial[#partial + 1] = name
		end
	end

	if #exact == 1 then
		return exact[1], {}
	end
	if #exact > 1 then
		table.sort(exact)
		return nil, exact
	end
	table.sort(partial)
	return nil, partial
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local db

local function ensureDB()
	DeathlogWatchDB = DeathlogWatchDB or {}
	db = DeathlogWatchDB
	db.events = db.events or {}
	db.senders = db.senders or {}
	db.checksums = db.checksums or {}
	db.started = db.started or GetServerTime()
end

local function senderRecord(name)
	local rec = db.senders[name]
	if not rec then
		rec = {
			pings = 0,
			self_pings = 0,
			peer_pings = 0,
			reported = 0,
			corroborations = 0,
			victims = {},
			first = GetServerTime(),
		}
		db.senders[name] = rec
	end
	return rec
end

local function pushEvent(ev)
	local events = db.events
	events[#events + 1] = ev
	if #events > MAX_EVENTS then
		-- Drop the oldest quarter in one pass rather than shifting per insert.
		local trimmed = {}
		local start = math.floor(MAX_EVENTS / 4)
		for i = start, #events do
			trimmed[#trimmed + 1] = events[i]
		end
		db.events = trimmed
	end
end

local function pruneChecksums()
	local now = GetServerTime()
	for cs, rec in pairs(db.checksums) do
		if (now - (rec.t or 0)) > CHECKSUM_TTL then
			db.checksums[cs] = nil
		end
	end
end

local function victimNameSet()
	local set = {}
	for _, ev in ipairs(db.events) do
		if ev.kind == "ping" then
			set[ev.victim] = true
		end
	end
	return set
end

local function senderNameSet()
	local set = {}
	for name in pairs(db.senders) do
		set[name] = true
	end
	return set
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

local function onDeathPing(sender, payload)
	local pd = decodeMessage(payload)
	if not pd or pd.name == "" then
		return
	end

	local victim = pd.name
	local is_self = (sender == victim)
	local checksum = fletcher16(pd)

	local rec = senderRecord(sender)
	rec.pings = rec.pings + 1
	rec.last = GetServerTime()
	rec.victims[victim] = (rec.victims[victim] or 0) + 1
	if is_self then
		rec.self_pings = rec.self_pings + 1
	else
		rec.peer_pings = rec.peer_pings + 1
	end
	if pd.source_id == -1 then
		rec.reported = rec.reported + 1
	end

	local cs = db.checksums[checksum]
	if not cs then
		cs = { victim = victim, origin = sender, corroborators = {}, t = GetServerTime() }
		db.checksums[checksum] = cs
	end

	pushEvent({
		t = GetServerTime(),
		kind = "ping",
		sender = sender,
		victim = victim,
		level = pd.level,
		guild = pd.guild,
		src = pd.source_id,
		self_report = is_self,
		cs = checksum,
	})
end

local function onChecksum(sender, payload)
	local checksum = payload:match("^(.-)~")
	if not checksum or checksum == "" then
		return
	end

	local rec = senderRecord(sender)
	rec.corroborations = rec.corroborations + 1
	rec.last = GetServerTime()

	local cs = db.checksums[checksum]
	if not cs then
		cs = { victim = checksum:match("^(.-)%-") or "?", corroborators = {}, t = GetServerTime() }
		db.checksums[checksum] = cs
	end
	-- The library itself dedups corroborations per sender; mirror that so
	-- one peer spamming checksums does not look like broad agreement.
	cs.corroborators[sender] = 1
end

---------------------------------------------------------------------------
-- Analysis
---------------------------------------------------------------------------

--- Number of peers other than the report's origin who corroborated it.
local function corroboratorCount(checksum, origin)
	local cs = db.checksums[checksum]
	if not cs then
		return 0
	end
	local n = 0
	for name in pairs(cs.corroborators) do
		if name ~= origin then
			n = n + 1
		end
	end
	return n
end

--- Per-sender signals that distinguish a normal client from a forger.
---
--- A normal client broadcasts its own death (self_pings) and occasionally
--- a party member's (peer_pings, corroborated by others who saw it).
--- A forger produces peer reports for players nobody else saw die.
local function analyseSender(name, rec)
	local uncorroborated, corroborated, reported_uncorrob = 0, 0, 0
	local distinct_victims = 0

	for _ in pairs(rec.victims) do
		distinct_victims = distinct_victims + 1
	end

	for _, ev in ipairs(db.events) do
		if ev.kind == "ping" and ev.sender == name and not ev.self_report then
			if corroboratorCount(ev.cs, name) > 0 then
				corroborated = corroborated + 1
			else
				uncorroborated = uncorroborated + 1
				if ev.src == -1 then
					reported_uncorrob = reported_uncorrob + 1
				end
			end
		end
	end

	-- Weighted: an uncorroborated "reported death" (source_id -1) is the
	-- cheapest forgery — it auto-commits without any peer agreement.
	local score = uncorroborated * 2 + reported_uncorrob * 3
	if distinct_victims > 5 and rec.self_pings == 0 then
		score = score + distinct_victims * 2
	end

	return {
		name = name,
		score = score,
		uncorroborated = uncorroborated,
		corroborated = corroborated,
		reported_uncorrob = reported_uncorrob,
		distinct_victims = distinct_victims,
		rec = rec,
	}
end

local function rankSenders()
	local out = {}
	for name, rec in pairs(db.senders) do
		local a = analyseSender(name, rec)
		if a.score > 0 then
			out[#out + 1] = a
		end
	end
	table.sort(out, function(x, y)
		if x.score == y.score then
			return x.name < y.name
		end
		return x.score > y.score
	end)
	return out
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local function out(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[DLWatch]|r " .. msg)
end

local function stamp(t)
	return date("%m/%d %H:%M:%S", t)
end

local function buildReport()
	local lines = {}
	local function add(s)
		lines[#lines + 1] = s
	end

	local ranked = rankSenders()
	local total_senders = 0
	for _ in pairs(db.senders) do
		total_senders = total_senders + 1
	end

	add(("DeathlogWatch report — %s"):format(stamp(GetServerTime())))
	add(("Collecting since %s | %d senders seen | %d events"):format(stamp(db.started), total_senders, #db.events))
	add("")
	add("Suspicious senders (uncorroborated peer reports):")
	add(padRight("SENDER", 16) .. " " .. ("%6s %6s %6s %6s %6s"):format("SCORE", "UNCOR", "COR", "SRC-1", "VICS"))

	if #ranked == 0 then
		add("  (none)")
	end
	for _, a in ipairs(ranked) do
		add(
			padRight(a.name, 16)
				.. " "
				.. ("%6d %6d %6d %6d %6d"):format(
					a.score,
					a.uncorroborated,
					a.corroborated,
					a.reported_uncorrob,
					a.distinct_victims
				)
		)
	end

	add("")
	add("UNCOR = peer reports no other client corroborated")
	add("SRC-1 = of those, ones flagged source_id=-1 (auto-commit, no corroboration needed)")
	return table.concat(lines, "\n")
end

local export_frame

local function showExport(text)
	if not export_frame then
		local f = CreateFrame("Frame", "DeathlogWatchExport", UIParent, "BasicFrameTemplateWithInset")
		f:SetSize(620, 440)
		f:SetPoint("CENTER")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		f.title:SetPoint("TOP", 0, -6)
		f.title:SetText("DeathlogWatch")

		local scroll = CreateFrame("ScrollFrame", "$parentScroll", f, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -32)
		scroll:SetPoint("BOTTOMRIGHT", -32, 12)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetFontObject(ChatFontNormal)
		edit:SetWidth(560)
		edit:SetAutoFocus(false)
		edit:SetScript("OnEscapePressed", function()
			f:Hide()
		end)
		scroll:SetScrollChild(edit)
		f.edit = edit
		export_frame = f
	end
	export_frame.edit:SetText(text)
	export_frame.edit:HighlightText()
	export_frame:Show()
end

--- Explain an empty result: the watcher only ever sees live channel
--- traffic, while Deathlog's own database is additionally backfilled by
--- background sync from peers.  A name can legitimately be in the
--- Deathlog UI and absent here.
local function explainMiss(candidates)
	if #candidates > 0 then
		out("  did you mean: |cffffff00" .. table.concat(candidates, "|r, |cffffff00", 1, math.min(#candidates, 8)) .. "|r")
		return
	end
	out(("  nothing matching in %d events collected since %s."):format(#db.events, stamp(db.started)))
	out("  note: DeathlogWatch only sees live broadcasts. Deathlog's own database is")
	out("  also backfilled by background sync, so older deaths appear there but not here.")
end

--- Collect the newest `limit` death pings matching `filter`, returned
--- OLDEST FIRST.
---
--- Chat scrolls downward, so a listing printed newest-first puts the line
--- you most want to read furthest from the input box, forcing a scroll.
--- Printing oldest-first lands the newest report on the last line.
---@param limit number
---@param filter fun(ev: table): boolean|nil
---@return table[] events  chronological order
---@return boolean truncated  true if older matches were left out
local function recentPings(limit, filter)
	local picked = {}
	local truncated = false

	for i = #db.events, 1, -1 do
		local ev = db.events[i]
		if ev.kind == "ping" and (not filter or filter(ev)) then
			if #picked >= limit then
				truncated = true
				break
			end
			picked[#picked + 1] = ev
		end
	end

	for i = 1, math.floor(#picked / 2) do
		local j = #picked - i + 1
		picked[i], picked[j] = picked[j], picked[i]
	end

	return picked, truncated
end

local function printSender(who)
	local matched, candidates = resolveName(who, senderNameSet())
	if not matched then
		out("no reports seen from |cffffff00" .. who .. "|r")
		explainMiss(candidates)
		return
	end
	who = matched
	local rec = db.senders[who]
	local a = analyseSender(who, rec)
	out(
		("|cffffff00%s|r — %d pings (%d self, %d peer), %d corroborations sent"):format(
			who,
			rec.pings,
			rec.self_pings,
			rec.peer_pings,
			rec.corroborations
		)
	)
	out(("  uncorroborated peer reports: |cffff5555%d|r  (source_id=-1: %d)"):format(a.uncorroborated, a.reported_uncorrob))

	local picked, truncated = recentPings(DEFAULT_LINES, function(ev)
		return ev.sender == who
	end)
	if truncated then
		out(("  ... older reports omitted, showing last %d (use /dlwatch export for all)"):format(#picked))
	end
	for _, ev in ipairs(picked) do
		local n = corroboratorCount(ev.cs, who)
		out(
			("  %s %s lvl%s src=%s %s"):format(
				stamp(ev.t),
				ev.victim,
				tostring(ev.level or "?"),
				tostring(ev.src or "?"),
				ev.self_report and "|cff55ff55self|r" or (n > 0 and ("|cff55ff55+" .. n .. " peers|r") or "|cffff5555UNCORROBORATED|r")
			)
		)
	end
end

local function printVictim(who)
	local matched, candidates = resolveName(who, victimNameSet())
	if not matched then
		out("reports claiming |cffffff00" .. who .. "|r died: (none)")
		explainMiss(candidates)
		return
	end
	who = matched

	out("reports claiming |cffffff00" .. who .. "|r died:")

	local picked, truncated = recentPings(DEFAULT_LINES, function(ev)
		return ev.victim == who
	end)
	if truncated then
		out(("  ... older reports omitted, showing last %d (use /dlwatch export for all)"):format(#picked))
	end
	for _, ev in ipairs(picked) do
		local n = corroboratorCount(ev.cs, ev.sender)
		out(
			("  %s from |cffffff00%s|r lvl%s src=%s %s"):format(
				stamp(ev.t),
				ev.sender,
				tostring(ev.level or "?"),
				tostring(ev.src or "?"),
				ev.self_report and "|cff55ff55self-report|r" or ("peer, " .. n .. " corroborations")
			)
		)
	end
end

--- Compact chat rendering of the suspicious-sender ranking.
---
--- Deliberately terser than buildReport(): that one goes to /dlwatch export,
--- which has a scrollable window to hold the legend and full column set.
--- Rows print worst-LAST so the top offender sits nearest the chat input.
---@param limit number|nil
local function printReport(limit)
	limit = math.max(1, math.min(tonumber(limit) or DEFAULT_LINES, MAX_LINES))

	local ranked = rankSenders()
	if #ranked == 0 then
		out(("no suspicious senders in %d events since %s"):format(#db.events, stamp(db.started)))
		return
	end

	local shown = math.min(#ranked, limit)
	if #ranked > shown then
		out(("... %d lower-scoring sender%s omitted, /dlwatch export for all"):format(
			#ranked - shown,
			(#ranked - shown) == 1 and "" or "s"
		))
	end
	out(padRight("SENDER", 14) .. " " .. ("%5s %5s %5s %5s"):format("SCORE", "UNCOR", "SRC-1", "VICS"))

	for i = shown, 1, -1 do
		local a = ranked[i]
		out(
			padRight(a.name, 14)
				.. " "
				.. ("%5d %5d %5d %5d"):format(a.score, a.uncorroborated, a.reported_uncorrob, a.distinct_victims)
		)
	end
	out(("worst listed last | %d event%s since %s"):format(#db.events, #db.events == 1 and "" or "s", stamp(db.started)))
end

local function printUsage()
	out("|cffffff00/dlwatch|r commands:")
	out("  report [n]     ranked suspicious senders")
	out("  recent [n]     latest reports seen")
	out("  sender <name>  everything one character broadcast")
	out("  victim <name>  who claimed this character died")
	out("  export         full report in a copy-paste window")
	out("  clear          wipe collected data")
	out(("watching — %d event%s since %s"):format(#db.events, #db.events == 1 and "" or "s", stamp(db.started)))
end

---@param limit number|nil  optional override, e.g. /dlwatch recent 40
local function printRecent(limit)
	limit = math.max(1, math.min(tonumber(limit) or DEFAULT_LINES, MAX_LINES))

	local picked, truncated = recentPings(limit, nil)
	if #picked == 0 then
		out("nothing captured yet")
		return
	end

	out(
		("last %d report%s%s — newest at the bottom:"):format(
			#picked,
			#picked == 1 and "" or "s",
			truncated and " (older omitted)" or ""
		)
	)
	for _, ev in ipairs(picked) do
		local n = corroboratorCount(ev.cs, ev.sender)
		out(
			("%s |cffffff00%s|r -> %s lvl%s src=%s %s"):format(
				stamp(ev.t),
				ev.sender,
				ev.victim,
				tostring(ev.level or "?"),
				tostring(ev.src or "?"),
				ev.self_report and "|cff55ff55self|r" or (n > 0 and ("+" .. n) or "|cffff5555UNCOR|r")
			)
		)
	end
end

---------------------------------------------------------------------------
-- Channel plumbing
---------------------------------------------------------------------------

local function hideChannel(name)
	local remove = (ChatFrameUtil and ChatFrameUtil.RemoveChannel) or ChatFrame_RemoveChannel
	if not remove then
		return
	end
	for i = 1, NUM_CHAT_WINDOWS do
		local frame = _G["ChatFrame" .. i]
		if frame then
			remove(frame, name)
		end
	end
end

--- Deathlog falls back to base.."b", base.."bb", ... when the main
--- channel is full, all sharing one password.  Sit on the first few.
local function joinChannels()
	for _, suffix in ipairs({ "", "b", "bb" }) do
		local name = CHANNEL_BASE .. suffix
		JoinChannelByName(name, CHANNEL_PW, nil, false)
		hideChannel(name)
	end
end

-- Suppress the password prompt popup for our channels.
hooksecurefunc("StaticPopup_Show", function(which, _, _, data)
	if type(data) == "string" and data:find(CHANNEL_BASE, 1, true) == 1 then
		StaticPopup_Hide(which)
	end
end)

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("CHAT_MSG_CHANNEL")

f:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON_NAME then
			ensureDB()
		end
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		ensureDB()
		C_Timer.After(6, joinChannels)
		C_Timer.NewTicker(300, pruneChecksums)
		return
	end

	-- CHAT_MSG_CHANNEL
	local text, sender_full, _, channel_desc = ...
	if not text or not channel_desc then
		return
	end

	local _, channel_name = string.split(" ", channel_desc)
	if not channel_name or channel_name:lower():find(CHANNEL_BASE, 1, true) ~= 1 then
		return
	end

	ensureDB()
	local command, payload = string.split(DELIM_CMD, text)
	if not payload then
		return
	end

	local sender = shortName(sender_full)
	if command == CMD_DEATH_PING then
		onDeathPing(sender, payload)
	elseif command == CMD_CHECKSUM then
		onChecksum(sender, payload)
	end
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

SLASH_DEATHLOGWATCH1 = "/dlwatch"
SlashCmdList["DEATHLOGWATCH"] = function(input)
	ensureDB()
	local cmd, arg = string.split(" ", ((input or ""):gsub("^%s+", "")))
	cmd = (cmd or ""):lower()

	if cmd == "report" then
		printReport(arg)
	elseif cmd == "sender" and arg and arg ~= "" then
		printSender(arg)
	elseif cmd == "victim" and arg and arg ~= "" then
		printVictim(arg)
	elseif cmd == "recent" then
		printRecent(arg)
	elseif cmd == "export" then
		showExport(buildReport())
	elseif cmd == "clear" then
		DeathlogWatchDB = nil
		ensureDB()
		out("collected data cleared")
	else
		printUsage()
	end
end
