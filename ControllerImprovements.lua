-- ControllerImprovements — overlay mode
--
-- Works WITH the native bank/vendor windows. The takeover approach (replacing
-- the windows) taints the gamepad interact-update chain on the Forever beta
-- and triggers the blocked-action popup for the rest of the session; see
-- README. This mode adds, without touching Blizzard's window/manager state:
--
--   X = one-press move: Deposit / Withdraw (bank), Sell / Buy / Buy Back (vendor)
--   an on-screen prompt line showing what X will do
--
-- Architecture cribbed from the working Inked addon: display-only overlay
-- (plain Show, never ShowUIPanel, mouse-disabled), read-only SmartNavigation
-- access (GetCurrentButton only), and engine item-move calls. X is polled
-- directly from the controller state — no binding calls, which also taint.

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
-- Display-only overlay (never ShowUIPanel — stays out of the window cycle)
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

------------------------------------------------------------
-- Focused-button identification (method sniffing on the NATIVE buttons)
------------------------------------------------------------

local function IsBagButton(button)
	return button and type(button.GetBagID) == "function";
end

local function IsBankButton(button)
	return button and type(button.GetBankTabID) == "function";
end

local function IsInteractionWindowShown()
	return (BankFrame and BankFrame:IsShown()) or (MerchantFrame and MerchantFrame:IsShown());
end

------------------------------------------------------------
-- X: one-press move
------------------------------------------------------------

local function CI_DoX()
	local button = SmartNavigation and SmartNavigation:GetCurrentButton() or nil;
	if not button then return; end
	if IsBagButton(button) then
		local bag, slot = button:GetBagID(), button:GetID();
		if MerchantFrame and MerchantFrame:IsShown() then
			-- Sell: the engine routes UseContainerItem to sell while the
			-- merchant interaction is open (same call Inked's Sell From Bags uses).
			pcall(C_Container.UseContainerItem, bag, slot);
		elseif BankFrame and BankFrame:IsShown() then
			-- Deposit (mainline deposit form; drop the bankType arg if ignored).
			local bankType = Enum.BankType and Enum.BankType.Character or nil;
			pcall(C_Container.UseContainerItem, bag, slot, nil, bankType, false);
		end
	elseif IsBankButton(button) then
		local tab, slot = button:GetBankTabID(), button:GetContainerSlotID();
		-- Withdraw (same call the camelot bank's own right-click uses).
		pcall(C_Container.UseContainerItem, tab, slot);
	elseif MerchantFrame and MerchantFrame:IsShown() then
		local index = button:GetID();
		if index then
			if MerchantFrame.selectedTab == 2 then
				if BuybackItem then pcall(BuybackItem, index); end
			elseif BuyMerchantItem then
				pcall(BuyMerchantItem, index);
			end
		end
	end
end

------------------------------------------------------------
-- Prompt line
------------------------------------------------------------

local function CI_UpdatePrompt()
	if not InputUtil.IsGamepadUIEnabled() or not IsInteractionWindowShown() then
		overlay:Hide();
		return;
	end
	overlay:Show();
	local button = SmartNavigation and SmartNavigation:GetCurrentButton() or nil;
	local text = "";
	if not button then
		-- nothing focused yet
	elseif CursorHasItem() then
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
	overlay.text:SetText(text);
end

------------------------------------------------------------
-- Poller: X press detection (fast, every frame) + prompt (0.2s)
------------------------------------------------------------

local prevButtons = {};
local poller = CreateFrame("Frame");
poller.elapsed = 0;
poller:SetScript("OnUpdate", function(self, elapsed)
	if not InputUtil.IsGamepadUIEnabled() then
		overlay:Hide();
		return;
	end
	local visible = IsInteractionWindowShown();
	if visible and C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonBindingToIndex then
		local state = C_GamePad.GetDeviceMappedState();
		if state and state.buttons then
			local index = C_GamePad.ButtonBindingToIndex("PAD3");
			if index then
				local down = state.buttons[index];
				if down and not prevButtons.PAD3 then
					CI_DoX();
				end
				prevButtons.PAD3 = down;
			end
		end
	end
	self.elapsed = self.elapsed + elapsed;
	if self.elapsed < 0.2 then return; end
	self.elapsed = 0;
	CI_UpdatePrompt();
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
			GetMerchantNumItems = GetMerchantNumItems ~= nil,
			GetMerchantItemInfo = GetMerchantItemInfo ~= nil,
		},
		GetMoney = GetMoney(),
	};
	print("ControllerImprovements: probe saved. Run /reload to write it to disk.");
end

function CI_BlockTest()
	local tests = {
		{ "SetOverrideBindingClick true", function()
			SetOverrideBindingClick(UIParent, true, "PAD3", "CIOverlay", "LeftButton");
		end },
		{ "SetOverrideBindingClick false", function()
			SetOverrideBindingClick(UIParent, false, "PAD3", "CIOverlay", "LeftButton");
		end },
		{ "SetOverrideBinding true", function()
			SetOverrideBinding(UIParent, true, "PAD3", "OPENALLBAGS");
		end },
		{ "SetOverrideBinding false", function()
			SetOverrideBinding(UIParent, false, "PAD3", "");
		end },
		{ "SetBindingClick (in-memory, no save)", function()
			SetBindingClick("PAD3", "CIOverlay", "LeftButton");
			SetBinding("PAD3");
		end },
	};
	for _, test in ipairs(tests) do
		print("CI blocktest:", test[1]);
		local ok, err = pcall(test[2]);
		if not ok then print("CI blocktest: error:", err); end
	end
	print("CI blocktest: complete");
end

SLASH_CONTROLLERIMPROVEMENTS1 = "/ci";
SlashCmdList.CONTROLLERIMPROVEMENTS = function(msg)
	msg = (msg or ""):lower();
	msg = msg:match("^%s*(.-)%s*$");
	if msg == "probe" then
		CI_Probe();
	elseif msg == "blocktest" then
		CI_BlockTest();
	elseif msg == "help" then
		print("ControllerImprovements: X = deposit/withdraw/sell/buy while bank/vendor is open. /ci probe | blocktest");
	end
end
