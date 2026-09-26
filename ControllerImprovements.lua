-- ControllerImprovements
-- Combined bank/vendor panel for gamepad on WoW Forever (camelot / retail 12.x).
--
-- Strategy: while a gamepad is active, opening the bank or a vendor suppresses
-- the native window (SetAlpha(0) -- never HideUIPanel, their OnHide closes the
-- interaction) and shows our side-by-side panel. Keyboard/mouse users are
-- untouched. Every API used here is insecure addon-callable Lua.

ControllerImprovementsDB = ControllerImprovementsDB or {};
ControllerImprovementsDB.LastForbidden = nil; -- fresh state per reload
ControllerImprovementsDB.RecentActions = {};

-- Action timeline ring (millisecond resolution) for correlating with the
-- forbidden-event timestamps.
function CI_LogAction(action)
	local entry = { action = action, time = time(), gameTime = GetTime() };
	ControllerImprovementsDB.LastAction = entry;
	local ring = ControllerImprovementsDB.RecentActions or {};
	ControllerImprovementsDB.RecentActions = ring;
	table.insert(ring, entry);
	while #ring > 8 do
		table.remove(ring, 1);
	end
end

-- The "blocked from an action only available to the Blizzard UI" popup does
-- not name the function; the ADDON_ACTION_FORBIDDEN event does. Log it.
local CI_ForbiddenFrame = CreateFrame("Frame");
CI_ForbiddenFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN");
CI_ForbiddenFrame:RegisterEvent("ADDON_ACTION_BLOCKED");
CI_ForbiddenFrame:SetScript("OnEvent", function(_, event, addonName, funcName)
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

-- Poller: runs outside all input-dispatch chains. Fast path (every frame):
-- reads X/Y/LB/RB directly from C_GamePad.GetDeviceMappedState (no bindings —
-- the binding system taints the interact-update chain on this client). Slow
-- path (0.2s): panel show/hide transitions, prompt, and the native-window close
-- AFTER the (fully Blizzard-owned) close chain completes.
local CI_LastPanelShown = false;
local CI_PrevButtons = {};
CI_ForbiddenFrame:SetScript("OnUpdate", function(frame, elapsed)
	if not CICombinedPanel then return; end
	local panel = CICombinedPanel;
	local shown = panel:IsShown();

	if shown and C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.ButtonBindingToIndex then
		local state = C_GamePad.GetDeviceMappedState();
		if state and state.buttons then
			local function pressed(key)
				local index = C_GamePad.ButtonBindingToIndex(key);
				if not index then return false; end
				local down = state.buttons[index];
				local wasDown = CI_PrevButtons[key];
				CI_PrevButtons[key] = down;
				return down and not wasDown;
			end
			if pressed("PAD3") then
				CI_LogAction("X");
				panel:CI_DoXAction(SmartNavigation:GetCurrentButton());
			end
			if pressed("PAD4") then
				panel:CI_SplitFocused();
			end
			if pressed("PADLSHOULDER") then
				panel:CI_PrevPage();
			end
			if pressed("PADRSHOULDER") then
				panel:CI_NextPage();
			end
		end
	end

	frame.pollElapsed = (frame.pollElapsed or 0) + elapsed;
	if frame.pollElapsed < 0.2 then return; end
	frame.pollElapsed = 0;
	if shown and not CI_LastPanelShown then
		panel:CI_RegisterRefreshEvents();
		panel:CI_UpdatePrompt();
	elseif CI_LastPanelShown and not shown then
		panel:CI_UnregisterRefreshEvents();
		panel:CI_AfterClose();
	elseif shown then
		panel:CI_UpdatePrompt();  -- poller doubles as the prompt updater
	end
	CI_LastPanelShown = shown;
end);

local CI_MERCHANT_PAGE_SIZE = MERCHANT_ITEMS_PER_PAGE or 10;
local CI_BUYBACK_PAGE_SIZE = BUYBACK_ITEMS_PER_PAGE or 12;
local CI_BAG_COLS = 12;                -- bag side grid width (continuous flow)
local CI_MAX_BANK_SECTIONS = 10;       -- base grid + up to 9 purchased tabs
local CI_MAX_BANK_SLOTS = 40;          -- per-section button cap
local CI_BUTTON_SPACING = 38;

-- Global-string fallbacks (classic globals may not exist on camelot).
local LABEL_PAGE_NUMBER = PAGE_NUMBER or "Page %d/%d";
local LABEL_BANK = BANK or "Bank";
local LABEL_MERCHANT = MERCHANT or "Vendor";

local NUM_CI_BAGS = NUM_BAG_SLOTS or 4;

local CI_FAILED_EVENTS = {};

------------------------------------------------------------
-- Data helpers (classic globals first, C_MerchantFrame fallback)
------------------------------------------------------------

function CI_GetMerchantItemInfo(index)
	if GetMerchantItemInfo then
		local name, texture, price, quantity, numAvailable = GetMerchantItemInfo(index);
		return name, texture, price, quantity, numAvailable;
	end
	local info = C_MerchantFrame.GetItemInfo(index);
	if info then
		return info.name, info.texture, info.price, info.stackCount, info.numAvailable;
	end
end

function CI_GetBuybackItemInfo(index)
	if GetBuybackItemInfo then
		local name, texture, price, quantity, numAvailable = GetBuybackItemInfo(index);
		return name, texture, price, quantity, numAvailable;
	end
	local info = C_MerchantFrame.GetBuybackItemInfo(index);
	if info then
		return info.name, info.texture, info.price, info.stackCount, info.numAvailable;
	end
end

function CI_GetMerchantNumItems()
	if GetMerchantNumItems then return GetMerchantNumItems(); end
	if C_MerchantFrame.GetNumItems then return C_MerchantFrame.GetNumItems(); end
	return 0;
end

function CI_GetNumBuybackItems()
	if GetNumBuybackItems then return GetNumBuybackItems(); end
	if C_MerchantFrame.GetNumBuybackItems then return C_MerchantFrame.GetNumBuybackItems(); end
	return 0;
end

-- Resolved fresh on every bank refresh: purchased tabs can change mid-session.
function CI_GetBankContainers()
	local containers = {};
	local meta = Enum.BagIndex and Enum.BagIndex.Characterbanktab or nil;
	if meta and (C_Container.GetContainerNumSlots(meta) or 0) >= 24 then
		table.insert(containers, meta);
	end
	if C_Bank and C_Bank.FetchPurchasedBankTabData then
		for _, tab in ipairs(C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character) or {}) do
			if tab.ID ~= meta then
				table.insert(containers, tab.ID);
			end
		end
	end
	if #containers == 0 and Enum.BagIndex then
		-- Fallback: scan CharacterBankTab_N for a >=24-slot container.
		for i = 1, 9 do
			local id = Enum.BagIndex["CharacterBankTab_" .. i];
			if id and (C_Container.GetContainerNumSlots(id) or 0) >= 24 then
				table.insert(containers, id);
			end
		end
	end
	return containers;
end

function CI_BankHasFreeSlot(containers)
	for _, container in ipairs(containers or {}) do
		local free = C_Container.GetContainerFreeSlots(container);
		if type(free) == "table" and #free > 0 then
			return true;
		elseif type(free) == "number" and free > 0 then
			return true;
		end
	end
	return false;
end

function CI_BagsHaveFreeSlot()
	if C_Container.CalculateTotalNumberOfFreeBagSlots then
		local free = C_Container.CalculateTotalNumberOfFreeBagSlots();
		if type(free) == "number" then return free > 0; end
	end
	for bag = 0, NUM_CI_BAGS do
		local free = C_Container.GetContainerFreeSlots(bag);
		if type(free) == "table" and #free > 0 then return true; end
	end
	return false;
end

------------------------------------------------------------
-- Panel mixin
------------------------------------------------------------

CICombinedPanelMixin = {};

function CICombinedPanelMixin:OnLoad()
	self:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true,
		tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } });
	self:SetBackdropColor(0, 0, 0, 0.85);
	self:SetBackdropBorderColor(0.4, 0.4, 0.4, 1);

	self.mode = nil;
	self.page = 1;
	self.suppressedFrame = nil;
	self.jumpOverrides = {};

	self.TitleText:SetPoint("TOPLEFT", self, "TOPLEFT", 16, -12);
	self.PageText:SetPoint("TOP", self, "TOP", 0, -14);
	self.MoneyDisplay:SetPoint("TOPRIGHT", self, "TOPRIGHT", -16, -12);
	self.BagSide:SetPoint("TOPLEFT", self, "TOPLEFT", 16, -40);
	self.RightSide:SetPoint("TOPLEFT", self, "TOPLEFT", 500, -40);

	-- Open events stay registered always. Close/refresh events are registered
	-- only while the panel is shown (poller) — their handlers must not run
	-- inside the engine's close chain (any of our code executing there taints
	-- the soft-interact -> SetPreferredGamepadInteractTarget path).
	for _, eventName in ipairs({ "BANKFRAME_OPENED", "MERCHANT_SHOW" }) do
		local ok = pcall(self.RegisterEvent, self, eventName);
		if not ok then
			table.insert(CI_FAILED_EVENTS, eventName);
		end
	end
	if #CI_FAILED_EVENTS > 0 then
		print("ControllerImprovements: unknown events:", table.concat(CI_FAILED_EVENTS, ", "));
	end

	self:CreateButtons();
	self.PromptText = self:CreateFontString(nil, "OVERLAY", "GameFontNormal");
	self.PromptText:SetPoint("BOTTOM", self, "BOTTOM", 0, 8);
	self.PromptText:SetTextColor(1, 1, 1, 1);
	self:RegisterForTransitions();
	-- Blizzard-scripted close button: SmartNavigation's B (AttemptClose) clicks
	-- it, so the close chain contains no addon code (avoids tainting the
	-- soft-interact -> SetPreferredGamepadInteractTarget chain -> blocked popup).
	self.CloseButton = CreateFrame("Button", "CICombinedPanelCloseButton", self, "UIPanelCloseButton");
	self.CloseButton:SetPoint("TOPRIGHT", self, "TOPRIGHT", -4, -4);
	-- Note: no SmartNavigation callbacks — they fire inside taintable chains
	-- (e.g. SelectedButtonUpdated during close). The poller updates the prompt.
end

function CICombinedPanelMixin:OnShow()
	-- No SmartNavigation callback installation: touching SmartNavigation state
	-- from addon code taints chains that pass through it. Focus lands on the
	-- first discovered button by default.
end

function CICombinedPanelMixin:OnEvent(event, ...)
	if not InputUtil.IsGamepadUIEnabled() then return; end
	if event == "BANKFRAME_OPENED" then
		self:OpenPanel("bank");
	elseif event == "MERCHANT_SHOW" then
		self:OpenPanel("vendor");
	elseif event == "MERCHANT_UPDATE" then
		if self:IsShown() and self.mode == "vendor" then
			self:RefreshMerchantSide();
			self:RefreshBuybackSide();
		end
	elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BANK_BAG_SLOT_FLAGS_UPDATED" or event == "BANK_TABS_CHANGED" then
		if self:IsShown() and self.mode == "bank" then self:RefreshBankSide(); end
	elseif event == "BAG_UPDATE" or event == "BAG_CONTAINER_UPDATE" then
		if self:IsShown() then self:RefreshBagSide(); end
	elseif event == "PLAYER_MONEY" then
		if self:IsShown() then MoneyFrame_Update(self.MoneyDisplay, GetMoney()); end
	end
end

------------------------------------------------------------
-- Open / close / native suppression
------------------------------------------------------------

function CICombinedPanelMixin:OpenPanel(mode)
	if not InputUtil.IsGamepadUIEnabled() then return; end
	-- Takeover is opt-in: on the Forever beta, any addon modification of the
	-- native bank/vendor windows taints the gamepad interact-update chain and
	-- triggers the blocked-action popup for the rest of the session. Enable
	-- with /ci enable once the client's restriction situation stabilizes.
	if not ControllerImprovementsDB.EnableTakeover then return; end
	CI_LogAction("OpenPanel:" .. mode);
	if self.mode == mode and self:IsShown() and self.suppressedFrame then
		self:RefreshAll();
		return;
	end
	self:RestoreSuppressed();
	self.mode = mode;
	self.page = 1;
	if mode == "bank" then
		self:SuppressNative(BankFrame);
		CloseAllBags(BankFrame);  -- native OnShow just opened them; keep bag ownership native
		self.TitleText:SetText(LABEL_BANK);
		self.BankContainer:Show();
		self.MerchantContainer:Hide();
		self.BuybackContainer:Hide();
	else
		self:SuppressNative(MerchantFrame);
		CloseAllBags(MerchantFrame);
		self.TitleText:SetText(LABEL_MERCHANT);
		self.BankContainer:Hide();
		self.MerchantContainer:Show();
		self.BuybackContainer:Show();
	end
	-- Refresh before ShowUIPanel: SmartNavigation discovers buttons at panel-open.
	local ok, err = pcall(self.RefreshAll, self);
	if not ok then
		-- A refresh bug must never leave the native window suppressed with our
		-- panel hidden (looks like a client crash). Restore and surface the error.
		self:RestoreSuppressed();
		print("ControllerImprovements: refresh failed:", err);
		return;
	end
	ShowUIPanel(self);
end

function CICombinedPanelMixin:ClosePanel()
	self:RestoreSuppressed();
	if self:IsShown() then
		HideUIPanel(self);
	end
end

function CICombinedPanelMixin:SuppressNative(frame)
	self.suppressedFrame = frame;
	if frame then
		frame:SetAlpha(0);
		-- Parent the native frame under our panel: when the panel hides (B-close
		-- via the Blizzard-scripted close button), the engine's child-hide
		-- propagation hides the native frame inside the CLEAN Blizzard chain, so
		-- its OnHide (C_Bank.CloseBankFrame / CloseMerchant) and the soft-interact
		-- event that follows fire untainted. Hiding it from our own code instead
		-- taints that chain and triggers the blocked popup.
		frame:SetParent(self);
		-- No FrameControlsManager calls: manipulating its state from addon code
		-- taints every chain that later passes through the manager.
	end
end

function CICombinedPanelMixin:RestoreSuppressed()
	local frame = self.suppressedFrame;
	self.suppressedFrame = nil;
	if frame then
		frame:SetAlpha(1);
		-- No SetParent here: reparenting a registered panel fires the panel
		-- machinery inside our tainted chain. The frame stays parented to our
		-- panel (hidden) and gets reparented on gamepad uninit (see below).
	end
end

-- Close cleanup, run from the poller AFTER the Blizzard close chain completes.
-- The native frame was already hidden by the child-hide propagation (B-close)
-- or by the engine (walk-away); here we just restore it for next time.
function CICombinedPanelMixin:CI_AfterClose()
	CI_LogAction("AfterClose");
	self:RestoreSuppressed();
	self.PromptText:SetText("");
end

------------------------------------------------------------
-- Button creation and refresh
------------------------------------------------------------

function CICombinedPanelMixin:CreateButtons()
	-- Bag side: continuous 12-col flow across backpack + bags.
	local maxBagButtons = NUM_CI_BAGS * 18 + 16 + 8;
	self.BagButtons = {};
	for i = 1, maxBagButtons do
		local button = CreateFrame("Button", nil, self.BagSide, "CIItemButtonTemplate");
		local col = (i - 1) % CI_BAG_COLS;
		local row = math.floor((i - 1) / CI_BAG_COLS);
		button:SetPoint("TOPLEFT", self.BagSide, "TOPLEFT", 4 + col * CI_BUTTON_SPACING, -4 - row * CI_BUTTON_SPACING);
		button:Init("bag", 0, 1, nil);
		button:Hide();
		table.insert(self.BagButtons, button);
	end

	-- Bank side: contiguous 4-col sections (base grid + purchased tabs).
	self.BankContainer = CreateFrame("Frame", nil, self.RightSide);
	self.BankContainer:SetAllPoints(self.RightSide);
	self.BankSections = {};
	for s = 1, CI_MAX_BANK_SECTIONS do
		local section = { Buttons = {} };
		for k = 1, CI_MAX_BANK_SLOTS do
			local button = CreateFrame("Button", nil, self.BankContainer, "CIItemButtonTemplate");
			local globalCol = (s - 1) * 4 + (k - 1) % 4;
			local row = math.floor((k - 1) / 4);
			button:SetPoint("TOPLEFT", self.BankContainer, "TOPLEFT", 4 + globalCol * CI_BUTTON_SPACING, -4 - row * CI_BUTTON_SPACING);
			button:Init("bank", nil, k, nil);
			button:Hide();
			table.insert(section.Buttons, button);
		end
		table.insert(self.BankSections, section);
	end

	-- Merchant: 5x2. Buyback: 6x2 below it.
	self.MerchantContainer = CreateFrame("Frame", nil, self.RightSide);
	self.MerchantContainer:SetPoint("TOPLEFT", self.RightSide, "TOPLEFT", 0, 0);
	self.MerchantButtons = {};
	for i = 1, CI_MERCHANT_PAGE_SIZE do
		local button = CreateFrame("Button", nil, self.MerchantContainer, "CIItemButtonTemplate");
		local col = (i - 1) % 5;
		local row = math.floor((i - 1) / 5);
		button:SetPoint("TOPLEFT", self.MerchantContainer, "TOPLEFT", 4 + col * CI_BUTTON_SPACING, -4 - row * CI_BUTTON_SPACING);
		button:Init("merchant", nil, nil, i);
		button:Hide();
		table.insert(self.MerchantButtons, button);
	end

	self.BuybackContainer = CreateFrame("Frame", nil, self.RightSide);
	self.BuybackContainer:SetPoint("TOPLEFT", self.MerchantContainer, "BOTTOMLEFT", 0, -20);
	self.BuybackButtons = {};
	for i = 1, CI_BUYBACK_PAGE_SIZE do
		local button = CreateFrame("Button", nil, self.BuybackContainer, "CIItemButtonTemplate");
		local col = (i - 1) % 6;
		local row = math.floor((i - 1) / 6);
		button:SetPoint("TOPLEFT", self.BuybackContainer, "TOPLEFT", 4 + col * CI_BUTTON_SPACING, -4 - row * CI_BUTTON_SPACING);
		button:Init("buyback", nil, nil, i);
		button:Hide();
		table.insert(self.BuybackButtons, button);
	end
end

function CICombinedPanelMixin:RefreshAll()
	self:RefreshBagSide();
	if self.mode == "bank" then
		self:RefreshBankSide();
	elseif self.mode == "vendor" then
		self:RefreshMerchantSide();
		self:RefreshBuybackSide();
	end
	MoneyFrame_Update(self.MoneyDisplay, GetMoney());
	self:CI_RebuildJumpOverrides();
	self:CI_UpdatePrompt();
end

function CICombinedPanelMixin:RefreshBagSide()
	local flat = {};
	for bag = 0, NUM_CI_BAGS do
		local slots = C_Container.GetContainerNumSlots(bag);
		for slot = 1, slots do
			table.insert(flat, { bag = bag, slot = slot });
		end
	end
	for i, button in ipairs(self.BagButtons) do
		local entry = flat[i];
		if entry then
			button:Init("bag", entry.bag, entry.slot, nil);
			button:Show();
			button:Refresh();
		else
			button:Hide();
		end
	end
end

function CICombinedPanelMixin:RefreshBankSide()
	local containers = CI_GetBankContainers();
	for s = 1, #self.BankSections do
		local container = containers[s];
		local slots = container and (C_Container.GetContainerNumSlots(container) or 0) or 0;
		for k, button in ipairs(self.BankSections[s].Buttons) do
			if k <= slots then
				button:Init("bank", container, k, nil);
				button:Show();
				button:Refresh();
			else
				button:Hide();
			end
		end
	end
end

function CICombinedPanelMixin:RefreshMerchantSide()
	local numItems = CI_GetMerchantNumItems();
	local numPages = math.max(1, math.ceil(numItems / CI_MERCHANT_PAGE_SIZE));
	self.page = math.min(self.page, numPages);
	for i = 1, CI_MERCHANT_PAGE_SIZE do
		local button = self.MerchantButtons[i];
		local index = (self.page - 1) * CI_MERCHANT_PAGE_SIZE + i;
		if index <= numItems then
			button:Init("merchant", nil, nil, index);
			button:Show();
			button:Refresh();
		else
			button:Hide();
		end
	end
	if numPages > 1 then
		self.PageText:SetText(string.format(LABEL_PAGE_NUMBER, self.page, numPages));
		self.PageText:Show();
	else
		self.PageText:Hide();
	end
end

function CICombinedPanelMixin:RefreshBuybackSide()
	local numItems = CI_GetNumBuybackItems();
	for i = 1, CI_BUYBACK_PAGE_SIZE do
		local button = self.BuybackButtons[i];
		if i <= numItems then
			button:Init("buyback", nil, nil, i);
			button:Show();
			button:Refresh();
		else
			button:Hide();
		end
	end
end

------------------------------------------------------------
-- D-pad jump overrides across the center gap
------------------------------------------------------------

function CICombinedPanelMixin:CI_RebuildJumpOverrides()
	-- Intentionally empty while grid nav is disabled (see SetupGamepad note).
end

------------------------------------------------------------
-- Move actions (X) and their conditions
------------------------------------------------------------

function CICombinedPanelMixin:CI_DoDeposit(button)
	button = button or SmartNavigation:GetCurrentButton();
	if not button or not button.hasItem then return; end
	-- Mainline deposit form; if bankType is ignored on camelot, drop the arg (classic form).
	local bankType = Enum.BankType and Enum.BankType.Character or nil;
	C_Container.UseContainerItem(button.bag, button.slot, nil, bankType, false);
	self:RefreshAll();
end

function CICombinedPanelMixin:CI_DoWithdraw(button)
	button = button or SmartNavigation:GetCurrentButton();
	if not button or not button.hasItem then return; end
	C_Container.UseContainerItem(button.bag, button.slot);
	self:RefreshAll();
end

function CICombinedPanelMixin:CI_DoSell(button)
	button = button or SmartNavigation:GetCurrentButton();
	if not button or not button.hasItem then return; end
	C_Container.UseContainerItem(button.bag, button.slot);
	self:RefreshAll();
end

function CICombinedPanelMixin:CI_DoBuy(button)
	button = button or SmartNavigation:GetCurrentButton();
	if not button then return; end
	BuyMerchantItem(button.index);
	self:RefreshAll();
end

function CICombinedPanelMixin:CI_DoBuyback(button)
	button = button or SmartNavigation:GetCurrentButton();
	if not button then return; end
	BuybackItem(button.index);
	self:RefreshAll();
end

function CICombinedPanelMixin:CI_PrevPage()
	if self.mode ~= "vendor" then return; end
	self.page = math.max(1, self.page - 1);
	self:RefreshMerchantSide();
	self:CI_UpdatePrompt();
end

function CICombinedPanelMixin:CI_NextPage()
	if self.mode ~= "vendor" then return; end
	local numPages = math.max(1, math.ceil(CI_GetMerchantNumItems() / CI_MERCHANT_PAGE_SIZE));
	self.page = math.min(numPages, self.page + 1);
	self:RefreshMerchantSide();
	self:CI_UpdatePrompt();
end

function CICombinedPanelMixin:CI_CondDeposit()
	if CursorHasItem() then return false; end
	local button = SmartNavigation:GetCurrentButton();
	if not (button and button.hasItem) or self.mode ~= "bank" then return false; end
	return CI_BankHasFreeSlot(CI_GetBankContainers());
end

function CICombinedPanelMixin:CI_CondWithdraw()
	if CursorHasItem() then return false; end
	local button = SmartNavigation:GetCurrentButton();
	if not (button and button.hasItem) or self.mode ~= "bank" then return false; end
	return CI_BagsHaveFreeSlot();
end

function CICombinedPanelMixin:CI_CondSell()
	if CursorHasItem() then return false; end
	local button = SmartNavigation:GetCurrentButton();
	if not (button and button.hasItem) or self.mode ~= "vendor" then return false; end
	if CanSellItems then return CanSellItems() == 1; end
	return true;
end

function CICombinedPanelMixin:CI_CondBuy()
	if CursorHasItem() then return false; end
	local button = SmartNavigation:GetCurrentButton();
	if not (button and button.hasItem) or self.mode ~= "vendor" then return false; end
	if CanAffordMerchantItem then return CanAffordMerchantItem(button.index) == 1; end
	return true;
end

function CICombinedPanelMixin:CI_CondSplitValid()
	local button = SmartNavigation:GetCurrentButton();
	if not button or CursorHasItem() then return false; end
	local info = button.bag and C_Container.GetContainerItemInfo(button.bag, button.slot) or nil;
	return info ~= nil and info.stackCount > 1 and not info.isLocked;
end

function CICombinedPanelMixin:CI_CondHasPages()
	return self.mode == "vendor" and CI_GetMerchantNumItems() > CI_MERCHANT_PAGE_SIZE;
end

-- Clone of Blizzard's Gamepad_SplitFocusedItemStack (ContainerFrame.lua).
function CICombinedPanelMixin:CI_SplitFocused()
	GamepadMode.FrameControlsManager:UnsuspendAllFrames();
	local button = SmartNavigation:GetCurrentButton();
	local info = button and button.bag and C_Container.GetContainerItemInfo(button.bag, button.slot) or nil;
	local count = info and info.stackCount;
	if not info or info.isLocked or not count or count <= 1 then return; end
	button.SplitStack = function(b, split)
		C_Container.SplitContainerItem(b.bag, b.slot, split);
	end
	GamepadMode.FrameControlsManager:SuspendFrameWithFooter();
	StackSplitFrame:OpenStackSplitFrame(count, button, "BOTTOMRIGHT", "TOPRIGHT");
	ShowUIPanel(StackSplitFrame);
end

------------------------------------------------------------
-- Gamepad lifecycle
------------------------------------------------------------

function CICombinedPanelMixin:RegisterForTransitions()
	InputUtil.RegisterForInterfaceTransitions(self, nil);
	InputUtil.RegisterGamepadInit(self, GenerateFlatClosure(self.InitializeGamepad, self));
	InputUtil.RegisterGamepadUninit(self, GenerateFlatClosure(self.UninitializeGamepad, self));
end

function CICombinedPanelMixin:InitializeGamepad()
end

function CICombinedPanelMixin:UninitializeGamepad()
	if self:IsShown() then
		self:ClosePanel();
	end
	-- Reparent any still-suppressed native frame back to UIParent so mouse-mode
	-- users see their windows again. Runs outside gamepad input chains.
	if self.suppressedFrame then
		self.suppressedFrame:SetParent(nil);
		self.suppressedFrame:SetAlpha(1);
		self.suppressedFrame = nil;
	end
end

-- No FocusGamepad/UnfocusGamepad methods and no binding calls at all:
-- X/Y/LB/RB are polled directly via C_GamePad.GetDeviceMappedState in the
-- poller. The binding system (plain and override) taints the interact-update
-- chain on this client, so the addon never touches it.

------------------------------------------------------------
-- Action buttons: X/Y/LB/RB route through the plain binding system. The
-- prompted-binding footer / override-binding stack is restricted for addons on
-- this client (blocked popup + hard freeze on close). D-pad/A/B stay on
-- SmartNavigation's own bindings. Bindings are in-memory only (SetBindingClick,
-- restored with SetBinding on unfocus).
------------------------------------------------------------

-- One-press move-to-other-side dispatch (X).
function CICombinedPanelMixin:CI_DoXAction(button)
	if not button then return; end
	CI_LogAction("X:" .. tostring(button.side));
	if self.mode == "bank" then
		if button.side == "bag" then
			self:CI_DoDeposit(button);
		elseif button.side == "bank" then
			self:CI_DoWithdraw(button);
		end
	elseif self.mode == "vendor" then
		if button.side == "bag" then
			self:CI_DoSell(button);
		elseif button.side == "merchant" then
			self:CI_DoBuy(button);
		elseif button.side == "buyback" then
			self:CI_DoBuyback(button);
		end
	end
end

-- Self-drawn prompt line (replaces the restricted footer prompts).
local CI_REFRESH_EVENTS = {
	"MERCHANT_UPDATE",
	"PLAYERBANKSLOTS_CHANGED",
	"BANK_BAG_SLOT_FLAGS_UPDATED",
	"BANK_TABS_CHANGED",
	"BAG_UPDATE",
	"BAG_CONTAINER_UPDATE",
	"PLAYER_MONEY",
};

function CICombinedPanelMixin:CI_RegisterRefreshEvents()
	for _, eventName in ipairs(CI_REFRESH_EVENTS) do
		pcall(self.RegisterEvent, self, eventName);
	end
end

function CICombinedPanelMixin:CI_UnregisterRefreshEvents()
	for _, eventName in ipairs(CI_REFRESH_EVENTS) do
		self:UnregisterEvent(eventName);
	end
end

function CICombinedPanelMixin:CI_UpdatePrompt()
	if not self:IsShown() then
		self.PromptText:SetText("");
		return;
	end
	local parts = {};
	if CursorHasItem() then
		table.insert(parts, "A Place");
		table.insert(parts, "B Cancel");
	else
		local button = SmartNavigation:GetCurrentButton();
		if button then
			local xLabel = nil;
			if self.mode == "bank" then
				if button.side == "bag" and self:CI_CondDeposit() then
					xLabel = "Deposit";
				elseif button.side == "bank" and self:CI_CondWithdraw() then
					xLabel = "Withdraw";
				end
			elseif self.mode == "vendor" then
				if button.side == "bag" and self:CI_CondSell() then
					xLabel = "Sell";
				elseif button.side == "merchant" and self:CI_CondBuy() then
					xLabel = "Buy";
				elseif button.side == "buyback" then
					xLabel = "Buy Back";
				end
			end
			if xLabel then
				table.insert(parts, "X " .. xLabel);
			end
			if self:CI_CondSplitValid() then
				table.insert(parts, "Y Split");
			end
		end
		if self.mode == "vendor" and self:CI_CondHasPages() then
			table.insert(parts, "LB/RB Page");
		end
		table.insert(parts, "B Close");
	end
	self.PromptText:SetText(table.concat(parts, "   "));
end

------------------------------------------------------------
-- /ci debug commands
------------------------------------------------------------

-- Fires each suspect input-binding call once, with prints between, so we can
-- find which one triggers the "blocked" popup (don't interact with the popup —
-- /reload instead; it freezes the client on dismissal).
function CI_BlockTest()
	local tests = {
		{ "SetOverrideBindingClick true", function()
			SetOverrideBindingClick(UIParent, true, "PAD3", "CICombinedPanel", "LeftButton");
		end },
		{ "SetOverrideBindingClick false", function()
			SetOverrideBindingClick(UIParent, false, "PAD3", "CICombinedPanel", "LeftButton");
		end },
		{ "SetOverrideBinding true", function()
			SetOverrideBinding(UIParent, true, "PAD3", "OPENALLBAGS");
		end },
		{ "SetOverrideBinding false", function()
			SetOverrideBinding(UIParent, false, "PAD3", "");
		end },
		{ "SetBindingClick (in-memory, no save)", function()
			SetBindingClick("PAD3", "CICombinedPanel", "LeftButton");
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
			PickupMerchantItem = PickupMerchantItem ~= nil,
			BuyMerchantItem = BuyMerchantItem ~= nil,
			BuybackItem = BuybackItem ~= nil,
			GetMerchantNumItems = GetMerchantNumItems ~= nil,
			GetMerchantItemInfo = GetMerchantItemInfo ~= nil,
			GetNumBuybackItems = GetNumBuybackItems ~= nil,
			GetBuybackItemInfo = GetBuybackItemInfo ~= nil,
			CanAffordMerchantItem = CanAffordMerchantItem ~= nil,
			CanSellItems = CanSellItems ~= nil,
		},
		C_MerchantFrame = C_MerchantFrame ~= nil,
		MerchantNumItems = CI_GetMerchantNumItems(),
		BuybackNumItems = CI_GetNumBuybackItems(),
		BackpackFreeSlots = C_Container.GetContainerFreeSlots(Enum.BagIndex.Backpack),
		TotalFreeBagSlots = C_Container.CalculateTotalNumberOfFreeBagSlots and C_Container.CalculateTotalNumberOfFreeBagSlots() or nil,
		GetMoney = GetMoney(),
		FailedEvents = CI_FAILED_EVENTS,
	};
	print("ControllerImprovements: probe saved. Run /reload to write it to disk.");
end

SLASH_CONTROLLERIMPROVEMENTS1 = "/ci";
SlashCmdList.CONTROLLERIMPROVEMENTS = function(msg)
	msg = (msg or ""):lower();
	msg = msg:match("^%s*(.-)%s*$");
	local panel = CICombinedPanel;
	if msg == "probe" then
		CI_Probe();
	elseif msg == "blocktest" then
		CI_BlockTest();
	elseif msg == "open bank" then
		panel:OpenPanel("bank");
	elseif msg == "open vendor" then
		panel:OpenPanel("vendor");
	elseif msg == "close" then
		panel:ClosePanel();
	elseif msg == "enable" then
		ControllerImprovementsDB.EnableTakeover = true;
		print("ControllerImprovements: takeover enabled (beta warning: may trigger blocked-action popups). /ci disable to turn off.");
	elseif msg == "disable" then
		ControllerImprovementsDB.EnableTakeover = false;
		print("ControllerImprovements: takeover disabled.");
	else
		print("ControllerImprovements: /ci probe | blocktest | enable | disable | open bank | open vendor | close");
	end
end
