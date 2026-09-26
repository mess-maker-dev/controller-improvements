-- ControllerImprovements — combined bank/vendor navigation (Inked port)
--
-- While the bank or a vendor window is open with a gamepad:
--   * D-pad navigates across BOTH sides as one screen (bags <-> bank/vendor),
--     replacing the native per-window navigation — geometric movement over
--     the union of all slot buttons, driven through SmartNavigation.SelectButton.
--   * X performs a one-press move: Deposit / Withdraw / Sell / Buy / Buy Back.
--   * The bank/vendor window is nudged right-of-center so both sides sit
--     side-by-side.
--   * A (pick up/place) and B (close) stay on the native bindings.
--
-- Architecture is the Inked addon's, the one controller UI proven to work on
-- the Forever beta: raw SetOverrideBindingClick on our OWN manager frame
-- (never the footer/binding-group machinery, never UIParent), read-only
-- SmartNavigation calls, engine item-move calls, and frame repositioning
-- without any suppression. No ShowUIPanel of our own, no FrameControlsManager
-- calls, no native-frame alpha/parent tricks.

ControllerImprovementsDB = ControllerImprovementsDB or {};
ControllerImprovementsDB.LastForbidden = nil; -- fresh state per reload

-- The "blocked from an action only available to the Blizzard UI" popup does
-- not name the function; the ADDON_ACTION_FORBIDDEN event does. Log it.
local forbiddenFrame = CreateFrame("Frame");
forbiddenFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN");
forbiddenFrame:RegisterEvent("ADDON_ACTION_BLOCKED");
forbiddenFrame:SetScript("OnEvent", function(_, event, addonName, funcName)
	if addonName == "ControllerImprovements" then
		ControllerImprovementsDB.LastForbidden = {
			event = event,
			func = tostring(funcName),
			time = time(),
			gameTime = GetTime(),
			stack = debugstack(2, 40),
		};
		print("CI forbidden:", event, addonName, tostring(funcName));
	end
end);

------------------------------------------------------------
-- Input routing: hidden buttons + override bindings on our own manager frame
------------------------------------------------------------

local manager = CreateFrame("Frame", "CIManager", UIParent);
manager:Hide();

local function CreateNavButton(name, onClick)
	local button = CreateFrame("Button", name, manager);
	button:SetSize(1, 1);
	button:SetAlpha(0);
	button:SetPoint("CENTER");
	button:RegisterForClicks("LeftButtonUp");
	button:SetScript("OnClick", onClick);
	return button;
end

local navLeft, navRight, navUp, navDown, actionX;
local bindingsActive = false;
local needsRebind = false;
local needsClear = false;

local function ClearBindings()
	if InCombatLockdown and InCombatLockdown() then
		needsClear = true;
		return;
	end
	if ClearOverrideBindings then
		pcall(ClearOverrideBindings, manager);
	end
	bindingsActive = false;
	needsClear = false;
end

local function AddBinding(key, buttonName)
	if not key or key == "" or not SetOverrideBindingClick then return false; end
	return pcall(SetOverrideBindingClick, manager, true, key, buttonName, "LeftButton");
end

local function BindControls()
	if InCombatLockdown and InCombatLockdown() then
		needsRebind = true;
		return;
	end
	ClearBindings();
	AddBinding("PADDLEFT", "CINavLeft");
	AddBinding("PADDRIGHT", "CINavRight");
	AddBinding("PADDUP", "CINavUp");
	AddBinding("PADDDOWN", "CINavDown");
	AddBinding("PAD3", "CIActionX");
	bindingsActive = true;
	needsRebind = false;
end

------------------------------------------------------------
-- Context detection and candidate collection
------------------------------------------------------------

local function IsInteractionShown()
	return (BankFrame and BankFrame:IsShown()) or (MerchantFrame and MerchantFrame:IsShown());
end

local function CollectShownButtons(frame, out, depth)
	out = out or {};
	depth = depth or 0;
	if depth > 3 then return out; end
	for _, child in ipairs({ frame:GetChildren() }) do
		if child:IsShown() and child:IsObjectType("Button") then
			out[#out + 1] = child;
		end
		CollectShownButtons(child, out, depth + 1);
	end
	return out;
end

local function IsMerchantItemButton(button)
	if button.buttonContext == "ButtonContext_MerchantItemButton" then return true; end
	if button.GetName then
		local name = button:GetName();
		if type(name) == "string" and (name:match("^MerchantItem%d+ItemButton$") or name:match("Buyback")) then
			return true;
		end
	end
	return false;
end

local function IsBagButton(button)
	return button and type(button.GetSlotAndBagID) == "function" and not IsMerchantItemButton(button);
end

local function IsBankButton(button)
	return button and type(button.GetBankTabID) == "function";
end

local function GetCandidates()
	local out = {};
	-- Bags
	for i = 1, 6 do
		local bagFrame = _G["ContainerFrame" .. i];
		if bagFrame and bagFrame:IsShown() then
			local all = CollectShownButtons(bagFrame, {});
			for _, b in ipairs(all) do
				if IsBagButton(b) then out[#out + 1] = b; end
			end
		end
	end
	-- Bank
	if BankFrame and BankFrame:IsShown() then
		local all = CollectShownButtons(BankFrame, {});
		for _, b in ipairs(all) do
			if IsBankButton(b) then out[#out + 1] = b; end
		end
	end
	-- Merchant
	if MerchantFrame and MerchantFrame:IsShown() then
		local all = CollectShownButtons(MerchantFrame, {});
		for _, b in ipairs(all) do
			if IsMerchantItemButton(b) then out[#out + 1] = b; end
		end
		-- page + tab buttons
		for _, name in ipairs({ "MerchantPrevPageButton", "MerchantNextPageButton" }) do
			if _G[name] and _G[name]:IsShown() then out[#out + 1] = _G[name]; end
		end
		for i = 1, 2 do
			local tab = _G["MerchantFrameTab" .. i];
			if tab and tab:IsShown() then out[#out + 1] = tab; end
		end
	end
	return out;
end

local function GetCurrentButton()
	if SmartNavigation and SmartNavigation.GetCurrentButton then
		local ok, button = pcall(SmartNavigation.GetCurrentButton, SmartNavigation);
		if ok and button then return button; end
	end
	return nil;
end

local function SelectButton(button)
	if not button then return; end
	if SmartNavigation and SmartNavigation.SelectButton then
		pcall(SmartNavigation.SelectButton, SmartNavigation, button);
	end
end

------------------------------------------------------------
-- Geometric navigation over the candidate union (Inked's algorithm)
------------------------------------------------------------

local function FrameCenter(frame)
	if not frame or not frame.GetCenter then return nil, nil; end
	local ok, x, y = pcall(frame.GetCenter, frame);
	if ok then return x, y; end
end

local function LogNav(dir, from, to, count)
	local log = ControllerImprovementsDB.NavLog or {};
	ControllerImprovementsDB.NavLog = log;
	table.insert(log, { dir = dir, from = from, to = to, candidates = count, gameTime = GetTime() });
	while #log > 10 do
		table.remove(log, 1);
	end
end

local function Navigate(dxWanted, dyWanted)
	local current = GetCurrentButton();
	local candidates = GetCandidates();
	local dirName = dxWanted > 0 and "RIGHT" or dxWanted < 0 and "LEFT" or dyWanted > 0 and "UP" or "DOWN";
	if not current then
		-- Nothing focused: pick the top-left-most candidate.
		local best, bestX, bestY;
		for _, c in ipairs(candidates) do
			local x, y = FrameCenter(c);
			if x and (not bestX or y < bestY or (y == bestY and x < bestX)) then
				best, bestX, bestY = c, x, y;
			end
		end
		SelectButton(best);
		LogNav(dirName, "none", best and (best:GetName() or "?") or nil, #candidates);
		return;
	end
	local cx, cy = FrameCenter(current);
	if not cx then return; end
	local best, bestScore;
	for _, candidate in ipairs(candidates) do
		if candidate ~= current and candidate:IsShown() then
			local x, y = FrameCenter(candidate);
			if x and y then
				local dx, dy = x - cx, y - cy;
				local valid, primary, secondary;
				if dxWanted > 0 then
					valid = dx > 2;
					primary, secondary = dx, math.abs(dy);
				elseif dxWanted < 0 then
					valid = dx < -2;
					primary, secondary = -dx, math.abs(dy);
				elseif dyWanted > 0 then
					valid = dy > 2;
					primary, secondary = dy, math.abs(dx);
				else
					valid = dy < -2;
					primary, secondary = -dy, math.abs(dx);
				end
				if valid then
					local score = primary + (secondary * 2.4);
					if not bestScore or score < bestScore then
						best, bestScore = candidate, score;
					end
				end
			end
		end
	end
	SelectButton(best);
	LogNav(dirName, current:GetName() or "?", best and (best:GetName() or "?") or nil, #candidates);
end

------------------------------------------------------------
-- X: one-press move
------------------------------------------------------------

local function CI_DoX()
	local button = GetCurrentButton();
	if not button then return; end
	local ok, err;
	if IsBagButton(button) then
		local bag, slot = button:GetSlotAndBagID();
		if MerchantFrame and MerchantFrame:IsShown() then
			-- Sell: the engine routes UseContainerItem to sell while the
			-- merchant interaction is open (Inked's Sell From Bags call).
			ok, err = pcall(C_Container.UseContainerItem, bag, slot);
		elseif BankFrame and BankFrame:IsShown() then
			local bankType = Enum.BankType and Enum.BankType.Character or nil;
			ok, err = pcall(C_Container.UseContainerItem, bag, slot, nil, bankType, false);
		end
	elseif IsBankButton(button) then
		-- Withdraw (the camelot bank's own right-click call).
		ok, err = pcall(C_Container.UseContainerItem, button:GetBankTabID(), button:GetContainerSlotID());
	elseif IsMerchantItemButton(button) or (MerchantFrame and MerchantFrame:IsShown() and type(button.GetID) == "function") then
		local index = button:GetID();
		if index then
			if MerchantFrame.selectedTab == 2 then
				if BuybackItem then
					ok, err = pcall(BuybackItem, index);
				end
			elseif BuyMerchantItem then
				ok, err = pcall(BuyMerchantItem, index);
			end
		end
	end
	if not ok and err then
		ControllerImprovementsDB.LastError = { action = "X", error = err, time = time() };
		print("CI X error:", err);
	end
end

------------------------------------------------------------
-- Prompt overlay (display-only)
------------------------------------------------------------

local overlay = CreateFrame("Frame", "CIOverlay", UIParent);
overlay:SetSize(560, 44);
overlay:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 130);
overlay:SetFrameStrata("FULLSCREEN_DIALOG");
overlay:SetFrameLevel(400);
overlay:EnableMouse(false);
overlay:Hide();

overlay.bg = overlay:CreateTexture(nil, "BACKGROUND");
overlay.bg:SetAllPoints();
overlay.bg:SetColorTexture(0, 0, 0, 0.7);

overlay.text = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge");
overlay.text:SetPoint("CENTER");
overlay.text:SetTextColor(1, 1, 1, 1);

local function CI_UpdatePrompt()
	if not InputUtil.IsGamepadUIEnabled() or not IsInteractionShown() then
		overlay:Hide();
		return;
	end
	overlay:Show();
	local button = GetCurrentButton();
	local text = "";
	if button then
		if CursorHasItem() then
			text = "A Place   B Cancel";
		elseif IsBagButton(button) then
			if MerchantFrame and MerchantFrame:IsShown() then
				text = "X Sell";
			elseif BankFrame and BankFrame:IsShown() then
				text = "X Deposit";
			end
		elseif IsBankButton(button) then
			text = "X Withdraw";
		elseif MerchantFrame and MerchantFrame:IsShown() then
			if MerchantFrame.selectedTab == 2 then
				text = "X Buy Back";
			else
				text = "X Buy";
			end
		end
	end
	overlay.text:SetText(text);
end

------------------------------------------------------------
-- Window placement: nudge the bank/vendor right so both sides sit together
------------------------------------------------------------

local function PlaceWindow()
	local frame = nil;
	if BankFrame and BankFrame:IsShown() then
		frame = BankFrame;
	elseif MerchantFrame and MerchantFrame:IsShown() then
		frame = MerchantFrame;
	end
	if not frame then return; end
	-- Inked-proven (their Frame Mover): SetPoint on these windows is safe.
	if not frame.ciPlaced then
		frame.ciPlaced = true;
		frame:ClearAllPoints();
		frame:SetPoint("CENTER", UIParent, "CENTER", 160, 0);
	end
end

------------------------------------------------------------
-- Context poller: activate/deactivate bindings, placement, prompt
------------------------------------------------------------

local wasActive = false;
local poller = CreateFrame("Frame");
poller.elapsed = 0;
poller:SetScript("OnUpdate", function(self, elapsed)
	local active = InputUtil.IsGamepadUIEnabled() and IsInteractionShown();
	if active and not wasActive then
		BindControls();
		PlaceWindow();
		CI_UpdatePrompt();
	elseif not active and wasActive then
		ClearBindings();
		overlay:Hide();
	end
	wasActive = active;

	if needsRebind and active then
		BindControls();
	elseif needsClear and not active then
		ClearBindings();
	end

	self.elapsed = self.elapsed + elapsed;
	if self.elapsed < 0.2 then return; end
	self.elapsed = 0;
	if active then
		CI_UpdatePrompt();
	end
end);

------------------------------------------------------------
-- Wire the hidden buttons (created after their OnClick targets exist)
------------------------------------------------------------

navLeft = CreateNavButton("CINavLeft", function() Navigate(-1, 0); end);
navRight = CreateNavButton("CINavRight", function() Navigate(1, 0); end);
-- Inked's convention: UP = +1, DOWN = -1 (gamepad coordinate space).
navUp = CreateNavButton("CINavUp", function() Navigate(0, 1); end);
navDown = CreateNavButton("CINavDown", function() Navigate(0, -1); end);
actionX = CreateNavButton("CIActionX", function() CI_DoX(); end);

------------------------------------------------------------
-- /ci debug commands
------------------------------------------------------------

function CI_Probe()
	local tabs = {};
	if C_Bank and C_Bank.FetchPurchasedBankTabData then
		for _, tab in ipairs(C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character) or {}) do
			table.insert(tabs, { ID = tab.ID, name = tab.name, slots = C_Container.GetContainerNumSlots(tab.ID) });
		end
	end
	ControllerImprovementsDB.Probe = {
		NUM_BAG_SLOTS = NUM_BAG_SLOTS,
		CharacterbanktabSlots = C_Container.GetContainerNumSlots(Enum.BagIndex.Characterbanktab),
		PurchasedBankTabs = tabs,
		MerchantGlobals = {
			BuyMerchantItem = BuyMerchantItem ~= nil,
			BuybackItem = BuybackItem ~= nil,
		},
		GetMoney = GetMoney(),
	};
	print("ControllerImprovements: probe saved. Run /reload to write it to disk.");
end

SLASH_CONTROLLERIMPROVEMENTS1 = "/ci";
SlashCmdList.CONTROLLERIMPROVEMENTS = function(msg)
	msg = (msg or ""):lower();
	msg = msg:match("^%s*(.-)%s*$");
	if msg == "probe" then
		CI_Probe();
	elseif msg == "nav" then
		-- debug: dump candidate names + current button
		local candidates = GetCandidates();
		local names = {};
		for i = 1, math.min(#candidates, 30) do
			local c = candidates[i];
			names[#names + 1] = c:GetName() or "?";
		end
		local current = GetCurrentButton();
		ControllerImprovementsDB.NavDebug = {
			candidates = #candidates,
			names = names,
			current = current and (current:GetName() or current:GetObjectType()) or nil,
		};
		print("CI nav:", #candidates, "candidates, current:", current and (current:GetName() or current:GetObjectType()) or "none");
	else
		print("ControllerImprovements: D-pad navigates bags+bank/vendor as one screen; X = deposit/withdraw/sell/buy. /ci probe | nav");
	end
end
