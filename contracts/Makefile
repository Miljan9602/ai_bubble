# AI.Bubble Smart Contract Deployment
# Usage: make deploy / make start-game CONTROLLER=0x...

include ../.env

# ============================================================================
# Build & Test
# ============================================================================

.PHONY: build test test-fuzz test-invariant snapshot

build:
	forge build

test:
	forge test -vvv

test-fuzz:
	forge test --fuzz-runs 10000 -vvv

test-invariant:
	forge test --mt invariant -vvv

snapshot:
	forge snapshot

# ============================================================================
# Deploy
# ============================================================================

.PHONY: deploy

deploy:
	@echo "=== DEPLOYING CONTRACTS ==="
	@echo "RPC: $(RPC_URL)"
	@echo "Double-check everything before proceeding!"
	@read -p "Are you sure? (y/N) " confirm && [ "$$confirm" = "y" ] || exit 1
	forge script script/Deploy.s.sol:DeployScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--legacy \
		--slow \
		-vvvv

# ============================================================================
# Redeploy (keep BubbleToken, redeploy everything else)
# ============================================================================

.PHONY: redeploy

redeploy:
	@echo "=== REDEPLOYING CONTRACTS (keeping BubbleToken) ==="
	@echo "RPC: $(RPC_URL)"
	@echo "Existing token: $(EXISTING_BUBBLE_TOKEN)"
	@echo "Old Farm: $(OLD_FARM) | Old GPU: $(OLD_GPU) | Old Controller: $(OLD_CONTROLLER)"
	@echo "Double-check everything before proceeding!"
	@read -p "Are you sure? (y/N) " confirm && [ "$$confirm" = "y" ] || exit 1
	forge script script/Redeploy.s.sol:RedeployScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--legacy \
		--slow \
		-vvvv

# ============================================================================
# Post-Deploy: Start Game
# ============================================================================

.PHONY: start-game

# Usage: make start-game CONTROLLER=0x...
start-game:
	@echo "=== STARTING GAME ==="
	@echo "GameController: $(CONTROLLER)"
	@read -p "Are you sure? (y/N) " confirm && [ "$$confirm" = "y" ] || exit 1
	cast send $(CONTROLLER) "startGame(uint256)" $$(date +%s) \
		--rpc-url $(RPC_URL) \
		--private-key $(DEPLOYER_PRIVATE_KEY)

# ============================================================================
# Gas Report
# ============================================================================

.PHONY: gas-report

gas-report:
	forge test --gas-report

# ============================================================================
# Clean
# ============================================================================

.PHONY: clean

clean:
	forge clean
