// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DTSC} from "../core/DTSC.sol";
import {HexPriceOracle} from "../oracle/HexPriceOracle.sol";
import {HexPriceAggregator} from "../oracle/HexPriceAggregator.sol";
import {IHexPriceOracle} from "../oracle/IHexPriceOracle.sol";
import {TShareValuation} from "../valuation/TShareValuation.sol";
import {RecoveryModule} from "../core/RecoveryModule.sol";
import {VaultManager} from "../core/VaultManager.sol";
import {StabilityPool} from "../core/StabilityPool.sol";
import {RedemptionHandler} from "../core/RedemptionHandler.sol";
import {BuybackBurn} from "../core/BuybackBurn.sol";
import {PenaltyRouter} from "../core/PenaltyRouter.sol";
import {DTSCConstants as C} from "../libraries/DTSCConstants.sol";
import {PulseChainAddresses as A} from "../config/PulseChainAddresses.sol";

struct DTSCSystem {
    DTSC dtsc;
    IHexPriceOracle oracle;
    HexPriceOracle hexUsdcOracle;
    HexPriceOracle hexWplsOracle;
    HexPriceOracle wplsUsdcOracle;
    TShareValuation valuation;
    RecoveryModule recovery;
    VaultManager vaultManager;
    StabilityPool stabilityPool;
    RedemptionHandler redemptionHandler;
    BuybackBurn buybackBurn;
    PenaltyRouter penaltyRouter;
}

struct OraclePairs {
    address hexUsdcPair;
    address hexWplsPair;
    address wplsUsdcPair;
}

contract DTSCDeployer {
    event SystemDeployed(DTSCSystem system);

    /// @dev Test / dev deploy with a single quote pair (18-decimal mock or WPLS)
    function deploy(
        address hexContract,
        address hexToken,
        address quoteToken,
        address hexQuotePair,
        address dexRouter
    ) external returns (DTSCSystem memory sys) {
        OraclePairs memory pairs =
            OraclePairs({hexUsdcPair: address(0), hexWplsPair: hexQuotePair, wplsUsdcPair: address(0)});
        return _deploy(hexContract, hexToken, quoteToken, quoteToken, pairs, dexRouter, false);
    }

    function deployWithOptions(
        address hexContract,
        address hexToken,
        address quoteToken,
        address hexQuotePair,
        address dexRouter,
        bool enableRegisteredVaults
    ) public returns (DTSCSystem memory sys) {
        OraclePairs memory pairs =
            OraclePairs({hexUsdcPair: address(0), hexWplsPair: hexQuotePair, wplsUsdcPair: address(0)});
        return _deploy(hexContract, hexToken, quoteToken, quoteToken, pairs, dexRouter, enableRegisteredVaults);
    }

    /// @notice Production deploy with USD price paths (HEX/USDC + cross rates)
    function deployProduction(
        address hexContract,
        OraclePairs calldata pairs,
        address dexRouter,
        bool enableRegisteredVaults
    ) external returns (DTSCSystem memory sys) {
        return _deploy(hexContract, A.HEX, A.WPLS, A.USDC, pairs, dexRouter, enableRegisteredVaults);
    }

    function _deploy(
        address hexContract,
        address hexToken,
        address wplsToken,
        address usdcToken,
        OraclePairs memory pairs,
        address dexRouter,
        bool enableRegisteredVaults
    ) internal returns (DTSCSystem memory sys) {
        require(pairs.hexWplsPair != address(0), "hex/wpls pair required");

        sys.dtsc = new DTSC();

        sys.hexWplsOracle = new HexPriceOracle(
            hexToken,
            uint8(C.HEX_TOKEN_DECIMALS),
            wplsToken,
            uint8(C.WPLS_DECIMALS),
            pairs.hexWplsPair,
            C.MIN_HEX_RESERVE_HEARTS,
            C.MIN_QUOTE_RESERVE_WPLS
        );

        if (pairs.hexUsdcPair != address(0)) {
            sys.hexUsdcOracle = new HexPriceOracle(
                hexToken,
                uint8(C.HEX_TOKEN_DECIMALS),
                usdcToken,
                uint8(C.USDC_DECIMALS),
                pairs.hexUsdcPair,
                C.MIN_HEX_RESERVE_HEARTS,
                C.MIN_QUOTE_RESERVE_USDC
            );
        }

        if (pairs.wplsUsdcPair != address(0)) {
            sys.wplsUsdcOracle = new HexPriceOracle(
                wplsToken,
                uint8(C.WPLS_DECIMALS),
                usdcToken,
                uint8(C.USDC_DECIMALS),
                pairs.wplsUsdcPair,
                C.MIN_QUOTE_RESERVE_WPLS,
                C.MIN_QUOTE_RESERVE_USDC
            );
        }

        sys.oracle = IHexPriceOracle(
            address(
                new HexPriceAggregator(
                    address(sys.hexUsdcOracle),
                    address(sys.hexWplsOracle),
                    address(sys.wplsUsdcOracle),
                    address(0)
                )
            )
        );

        sys.valuation = new TShareValuation(hexContract, address(sys.oracle));
        sys.recovery = new RecoveryModule();
        sys.buybackBurn = new BuybackBurn(address(sys.dtsc), dexRouter, usdcToken);
        sys.stabilityPool = new StabilityPool(address(sys.dtsc));
        sys.penaltyRouter = new PenaltyRouter(
            address(sys.dtsc), address(sys.stabilityPool), address(sys.buybackBurn)
        );
        sys.buybackBurn.setPenaltyRouter(address(sys.penaltyRouter));

        sys.vaultManager = new VaultManager(
            hexContract,
            address(sys.dtsc),
            address(sys.valuation),
            address(sys.recovery),
            address(sys.penaltyRouter)
        );

        sys.recovery.setVaultManager(address(sys.vaultManager));
        sys.recovery.renounceDeployer();

        sys.stabilityPool.setVaultManager(address(sys.vaultManager));
        sys.stabilityPool.setPenaltyRouter(address(sys.penaltyRouter));
        sys.stabilityPool.renounceDeployer();

        sys.penaltyRouter.setVaultManager(address(sys.vaultManager));
        sys.penaltyRouter.renounceDeployer();

        sys.vaultManager.setStabilityPool(address(sys.stabilityPool));
        if (enableRegisteredVaults) {
            sys.vaultManager.setRegisteredVaultsEnabled(true);
        }
        sys.redemptionHandler = new RedemptionHandler(
            address(sys.dtsc), address(sys.vaultManager), address(sys.buybackBurn)
        );
        sys.vaultManager.setRedemptionHandler(address(sys.redemptionHandler));
        sys.vaultManager.finalizeSetup();

        sys.dtsc.authorizeMinter(address(sys.vaultManager), true);
        sys.dtsc.authorizeMinter(address(sys.stabilityPool), true);
        sys.dtsc.authorizeMinter(address(sys.redemptionHandler), true);
        sys.dtsc.authorizeMinter(address(sys.buybackBurn), true);
        sys.dtsc.lockWiring();

        emit SystemDeployed(sys);
    }
}