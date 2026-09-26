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

-- Input: no binding calls at all. Mutating the binding system from addon code
-- (SetOverrideBindingClick, SetBinding, ClearOverrideBindings — even Inked's
-- raw form) taints the shared binding state on this beta; the blocked popup
-- fires later, whenever the interact-icon update runs (close teardown, target
-- changes). X and the cross-gap bridge are polled from the controller state.
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

local function IsBankButton(button)
	return button and type(button.GetBankTabID) == "function";
end

local function IsBagButton(button)
	-- Bag item buttons only: GetSlotAndBagID identifies the container-button
	-- mixin. Bank buttons also expose GetID, so the loose fallback would
	-- misclassify them as bags — check bank first. The bag-itself icons have
	-- the method too but return a nil bag; exclude them.
	if not button or IsMerchantItemButton(button) or IsBankButton(button) then return false; end
	if type(button.GetSlotAndBagID) ~= "function" then return false; end
	local ok, slot, bag = pcall(button.GetSlotAndBagID, button);
	return ok and bag ~= nil;
end

local function GetCandidates()
	local out = {};
	-- Bags: the camelot client uses the COMBINED bags frame; individual
	-- ContainerFrame1..5 also exist for the classic layout.
	local bagFrames = {};
	for i = 1, 6 do
		local bagFrame = _G["ContainerFrame" .. i];
		if bagFrame and bagFrame:IsShown() then
			bagFrames[#bagFrames + 1] = bagFrame;
		end
	end
	local combined = _G.ContainerFrameCombinedBags;
	if combined and combined:IsShown() then
		bagFrames[#bagFrames + 1] = combined;
	end
	for _, bagFrame in ipairs(bagFrames) do
		local all = CollectShownButtons(bagFrame, {});
		for _, b in ipairs(all) do
			if IsBagButton(b) then out[#out + 1] = b; end
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
-- X: one-press move
------------------------------------------------------------

local function LogX(kind, name, detail)
	local log = ControllerImprovementsDB.XLog or {};
	ControllerImprovementsDB.XLog = log;
	table.insert(log, { kind = kind, name = name, detail = detail, gameTime = GetTime() });
	while #log > 8 do
		table.remove(log, 1);
	end
end

local function CI_DoX()
	-- On the bank/vendor side use OUR tracked button — the native cursor
	-- position is not trustworthy there.
	local button = (ciSide == "other" and ciOtherButton) or GetCurrentButton();
	if not button then
		LogX("nofocus", nil, nil);
		return;
	end
	local name = button:GetName() or "?";
	local ok, err;
	if IsBankButton(button) then
		-- Withdraw (the camelot bank's own right-click call).
		local tab, slot = button:GetBankTabID(), button:GetContainerSlotID();
		ok, err = pcall(C_Container.UseContainerItem, tab, slot);
		LogX("withdraw", name, ("tab=%s slot=%s"):format(tostring(tab), tostring(slot)));
	elseif IsBagButton(button) then
		-- Returns slot, bag — order matters.
		local slot, bag = button:GetSlotAndBagID();
		if not bag or not slot then
			LogX("bag-itself", name, nil);
			return;
		end
		if MerchantFrame and MerchantFrame:IsShown() then
			-- Sell: the engine routes UseContainerItem to sell while the
			-- merchant interaction is open (Inked's Sell From Bags call).
			ok, err = pcall(C_Container.UseContainerItem, bag, slot);
			LogX("sell", name, ("bag=%s slot=%s"):format(tostring(bag), tostring(slot)));
		elseif BankFrame and BankFrame:IsShown() then
			local bankType = Enum.BankType and Enum.BankType.Character or nil;
			ok, err = pcall(C_Container.UseContainerItem, bag, slot, nil, bankType, false);
			LogX("deposit", name, ("bag=%s slot=%s"):format(tostring(bag), tostring(slot)));
		else
			LogX("bag-nocontext", name, nil);
		end
	elseif IsMerchantItemButton(button) or (MerchantFrame and MerchantFrame:IsShown() and type(button.GetID) == "function") then
		local index = button:GetID();
		if index then
			if MerchantFrame.selectedTab == 2 then
				if BuybackItem then
					ok, err = pcall(BuybackItem, index);
					LogX("buyback", name, ("index=%s"):format(tostring(index)));
				else
					LogX("buyback-nofn", name, nil);
				end
			elseif BuyMerchantItem then
				ok, err = pcall(BuyMerchantItem, index);
				LogX("buy", name, ("index=%s"):format(tostring(index)));
			else
				LogX("buy-nofn", name, nil);
			end
		end
	else
		LogX("unclassified", name, nil);
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
	local button = (ciSide == "other" and ciOtherButton) or GetCurrentButton();
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
-- Window placement: WE own the layout. Bags pinned left, bank/vendor pinned
-- right — the crossing directions are fixed by design, not measured.
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
	local combined = _G.ContainerFrameCombinedBags;
	if combined and combined:IsShown() and not combined.ciPlaced then
		combined.ciPlaced = true;
		combined:ClearAllPoints();
		combined:SetPoint("BOTTOMRIGHT", UIParent, "CENTER", -170, 0);
	end
end

-- Cached layout model: rightmost bag X and leftmost bank/merchant X,
-- recomputed on the slow tick (frames can resize).
local layoutBagsRight = nil;
local layoutOtherLeft = nil;

local function CI_UpdateLayout()
	layoutBagsRight = nil;
	layoutOtherLeft = nil;
	for _, b in ipairs(GetCandidates()) do
		local x = (b:GetLeft() + b:GetRight()) / 2;
		if IsBagButton(b) then
			if not layoutBagsRight or x > layoutBagsRight then
				layoutBagsRight = x;
			end
		else
			if not layoutOtherLeft or x < layoutOtherLeft then
				layoutOtherLeft = x;
			end
		end
	end
end

------------------------------------------------------------
-- Context poller: activate/deactivate bindings, placement, prompt
------------------------------------------------------------

-- Cross-gap bridges: the native nav handles movement WITHIN each side (bags
-- are natively navigable); we only intercept edge presses that should cross
-- the gap. Polled — no bindings.
local function GetCenterY(frame)
	return (frame:GetTop() + frame:GetBottom()) / 2;
end

local function FindClosestByY(buttons, y)
	local best, bestDist;
	for _, b in ipairs(buttons) do
		local d = math.abs(GetCenterY(b) - y);
		if not bestDist or d < bestDist then
			best, bestDist = b, d;
		end
	end
	return best;
end

-- Cross the gap in direction dxSign (+1 = RIGHT, -1 = LEFT): fire only from
-- an edge button of either side (no same-side button further in that
-- direction — frame edges are unreliable here), and jump to the nearest item
-- button of the OTHER side in the pressed direction. Works regardless of
-- whether the bank/vendor sits left or right of the bags.
local function LogBridge(dxSign, stage, detail)
	local log = ControllerImprovementsDB.BridgeLog or {};
	ControllerImprovementsDB.BridgeLog = log;
	table.insert(log, { dir = dxSign > 0 and "RIGHT" or "LEFT", stage = stage, detail = detail, gameTime = GetTime() });
	while #log > 12 do
		table.remove(log, 1);
	end
end

-- Side state: "bags" = native nav owns the cursor (its panel IS the bags);
-- "other" = we own navigation over the bank/vendor buttons, because
-- SmartNavigation's active panel never leaves the bags and would snap the
-- cursor back on the next native press.
local ciSide = "bags";
local ciOtherButton = nil;

local function FrameCenter(frame)
	if not frame or not frame.GetCenter then return nil, nil; end
	local ok, x, y = pcall(frame.GetCenter, frame);
	if ok then return x, y; end
end

local function OtherCandidates()
	local out = {};
	for _, b in ipairs(GetCandidates()) do
		if not IsBagButton(b) then out[#out + 1] = b; end
	end
	return out;
end

-- Geometric nav within the other side, from OUR tracked button (the native
-- cursor may be anywhere; its position is not trustworthy here).
local function NavOther(dxWanted, dyWanted)
	if not ciOtherButton then return; end
	local cx, cy = FrameCenter(ciOtherButton);
	if not cx then return; end
	local best, bestScore;
	for _, b in ipairs(OtherCandidates()) do
		local x, y = FrameCenter(b);
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
				local score = primary + secondary * 2.4;
				if not bestScore or score < bestScore then
					best, bestScore = b, score;
				end
			end
		end
	end
	if best then
		ciOtherButton = best;
		SelectButton(best);
	end
end

-- Cross back to the bags (row-first, from our tracked bank button).
local function CrossBackToBags()
	if not ciOtherButton then return; end
	local cx = FrameCenter(ciOtherButton);
	local cy = GetCenterY(ciOtherButton);
	local target, bestDist;
	for _, b in ipairs(GetCandidates()) do
		if IsBagButton(b) then
			local bx = FrameCenter(b);
			if bx then
				local d = math.abs(GetCenterY(b) - cy) * 10 + math.abs(bx - cx);
				if not bestDist or d < bestDist then
					target, bestDist = b, d;
				end
			end
		end
	end
	if target then
		ciSide = "bags";
		ciOtherButton = nil;
		SelectButton(target);
		LogBridge(-1, "crossed-back", target:GetName() or "?");
	end
end

-- Cross from the bags' right edge to the other side (row-first).
local function CrossToOther()
	local button = GetCurrentButton();
	if not IsBagButton(button) then return; end
	local cx = (button:GetLeft() + button:GetRight()) / 2;
	if not layoutBagsRight or cx < layoutBagsRight - 20 then return; end
	local cy = GetCenterY(button);
	local target, bestDist;
	for _, b in ipairs(OtherCandidates()) do
		local d = math.abs(GetCenterY(b) - cy) * 10 + math.abs((b:GetLeft() + b:GetRight()) / 2 - cx);
		if not bestDist or d < bestDist then
			target, bestDist = b, d;
		end
	end
	if target then
		ciSide = "other";
		ciOtherButton = target;
		SelectButton(target);
		LogBridge(1, "crossed", target:GetName() or "?");
	end
end

local wasActive = false;
local prevButtons = {};
local poller = CreateFrame("Frame");
poller.elapsed = 0;
poller:SetScript("OnUpdate", function(self, elapsed)
	local active = InputUtil.IsGamepadUIEnabled() and IsInteractionShown();
	if active and not wasActive then
		PlaceWindow();
		CI_UpdatePrompt();
	elseif not active and wasActive then
		ciSide = "bags";
		ciOtherButton = nil;
		overlay:Hide();
	end
	wasActive = active;

	if active and C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonBindingToIndex then
		local state = C_GamePad.GetDeviceMappedState();
		if state and state.buttons then
			local function pressed(key)
				local index = C_GamePad.ButtonBindingToIndex(key);
				if not index then return false; end
				local down = state.buttons[index];
				local wasDown = prevButtons[key];
				prevButtons[key] = down;
				return down and not wasDown;
			end
			if pressed("PAD3") then
				CI_DoX();
			end
			if pressed("PADDRIGHT") then
				if ciSide == "bags" then
					CrossToOther();
				else
					NavOther(1, 0);
				end
			end
			if pressed("PADDLEFT") then
				if ciSide == "other" then
					local cx = ciOtherButton and FrameCenter(ciOtherButton);
					if cx and layoutOtherLeft and cx <= layoutOtherLeft + 20 then
						CrossBackToBags();
					else
						NavOther(-1, 0);
					end
				end
				-- bags side: native nav owns LEFT
			end
			if pressed("PADDUP") then
				if ciSide == "other" then
					NavOther(0, -1);
				end
			end
			if pressed("PADDDOWN") then
				if ciSide == "other" then
					NavOther(0, 1);
				end
			end
		end
	end

	self.elapsed = self.elapsed + elapsed;
	if self.elapsed < 0.2 then return; end
	self.elapsed = 0;
	if active then
		CI_UpdateLayout();
		CI_UpdatePrompt();
	end
end);

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
