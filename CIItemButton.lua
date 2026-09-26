-- CIItemButtonMixin
-- One item button mixin for all four slot kinds:
--   side "bag"      -> fields bag, slot   (player containers)
--   side "bank"     -> fields bag, slot   (bank container, bag = container ID)
--   side "merchant" -> field  index
--   side "buyback"  -> field  index
-- The focused button's `buttonContext` drives the gamepad footer prompts.
--
-- Note: the 12.x SetItemButtonTexture/Count Lua wrappers expect named buttons
-- with intrinsic icon textures that our dynamically created buttons don't get.
-- We create the icon/count textures ourselves and set them directly, like the
-- camelot bank's own BankPanelItemButtonMixin does (self.icon:SetTexture).

CIItemButtonMixin = {};

local CONTEXT_BY_SIDE = {
	bag      = "ButtonContext_CI_BagItem",
	bank     = "ButtonContext_CI_BankItem",
	merchant = "ButtonContext_CI_MerchantItem",
	buyback  = "ButtonContext_CI_BuybackItem",
};

function CIItemButtonMixin:OnLoad()
	self:RegisterForClicks("LeftButtonUp");
	-- BankItemButtonTemplate copies its bank deposit/pickup drag handlers onto
	-- us (XML script inheritance); our buttons have no drag semantics.
	self:SetScript("OnDragStart", nil);
	self:SetScript("OnReceiveDrag", nil);

	self.icon = self.icon or self:CreateTexture(nil, "ARTWORK");
	self.icon:SetAllPoints();

	self.Count = self.Count or self:CreateFontString(nil, "OVERLAY", NumberFontNormal and "NumberFontNormal" or "GameFontNormalSmall");
	self.Count:SetPoint("BOTTOMRIGHT", 0, 2);

	self.hasItem = false;
	self.SplitStack = nil;
end

function CIItemButtonMixin:Init(side, bag, slot, index)
	self.side = side;
	self.bag = bag;
	self.slot = slot;
	self.index = index;
	self.buttonContext = CONTEXT_BY_SIDE[side];
	self.hasItem = false;
	if self.Money then
		self.Money:Hide();
	end
end

-- A-press (SmartNavigation:Click -> MouseDown+MouseUp -> OnClick).
function CIItemButtonMixin:OnClick(button)
	if button ~= "LeftButton" then
		return;
	end
	if ControllerImprovementsDB then
		CI_LogAction("A:" .. tostring(self.side));
	end
	if self.side == "bag" or self.side == "bank" then
		C_Container.PickupContainerItem(self.bag, self.slot);
	elseif self.side == "merchant" then
		PickupMerchantItem(self.index);
	elseif self.side == "buyback" then
		BuybackItem(self.index);
	end
end

function CIItemButtonMixin:OnEnter()
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	if self.side == "bag" or self.side == "bank" then
		if GameTooltip.SetBagItem then GameTooltip:SetBagItem(self.bag, self.slot); end
	elseif self.side == "merchant" then
		if GameTooltip.SetMerchantItem then GameTooltip:SetMerchantItem(self.index); end
	elseif self.side == "buyback" then
		if GameTooltip.SetBuybackItem then GameTooltip:SetBuybackItem(self.index); end
	end
	GameTooltip:Show();
	CursorUpdate(self);
end

function CIItemButtonMixin:OnLeave()
	GameTooltip:Hide();
	ResetCursor();
end

function CIItemButtonMixin:Refresh()
	if self.side == "bag" or self.side == "bank" then
		local info = self.bag and C_Container.GetContainerItemInfo(self.bag, self.slot) or nil;
		self.hasItem = info ~= nil;
		if info then
			self.icon:SetTexture(info.iconFileID);
			self.icon:SetDesaturated(info.isLocked);
			self.icon:Show();
			self.Count:SetText(info.stackCount > 1 and info.stackCount or "");
		else
			self.icon:SetTexture(nil);
			self.icon:Hide();
			self.Count:SetText("");
		end
		if info then
			local start, duration, enable = C_Container.GetContainerItemCooldown(self.bag, self.slot);
			CooldownFrame_Set(self.Cooldown, start, duration, enable);
		else
			CooldownFrame_Set(self.Cooldown, 0, 0, 0);
		end
	elseif self.side == "merchant" then
		local name, texture, price, quantity, numAvailable = CI_GetMerchantItemInfo(self.index);
		self.hasItem = name ~= nil;
		self.icon:SetTexture(texture);
		self.icon:Show();
		self.Count:SetText(numAvailable or quantity or "");
		if self.Money and price then
			MoneyFrame_Update(self.Money, price);
			self.Money:Show();
		elseif self.Money then
			self.Money:Hide();
		end
	elseif self.side == "buyback" then
		local name, texture, price, quantity, numAvailable = CI_GetBuybackItemInfo(self.index);
		self.hasItem = name ~= nil;
		self.icon:SetTexture(texture);
		self.icon:Show();
		self.Count:SetText(numAvailable or quantity or "");
		if self.Money and price then
			MoneyFrame_Update(self.Money, price);
			self.Money:Show();
		elseif self.Money then
			self.Money:Hide();
		end
	end
end
