// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DTSCDeployer, DTSCSystem, OraclePairs} from "../src/deploy/DTSCDeployer.sol";
import {PulseChainAddresses as A} from "../src/config/PulseChainAddresses.sol";
import {IPulseXFactory} from "../src/interfaces/IPulseXFactory.sol";

/// @notice PulseChain mainnet deployment — USD oracle aggregator
contract DeployDTSC is Script {
    function run() external returns (DTSCSystem memory sys) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        address hexWplsPair = IPulseXFactory(A.PULSEX_FACTORY_V2).getPair(A.HEX, A.WPLS);
        address hexUsdcPair = IPulseXFactory(A.PULSEX_FACTORY_V2).getPair(A.HEX, A.USDC);
        address wplsUsdcPair = IPulseXFactory(A.PULSEX_FACTORY_V2).getPair(A.WPLS, A.USDC);

        require(hexWplsPair != address(0), "HEX/WPLS pair missing");

        if (hexUsdcPair == address(0)) {
            console2.log("WARN: HEX/USDC pair not found, using cross-rate only");
        }
        if (wplsUsdcPair == address(0)) {
            console2.log("WARN: WPLS/USDC pair not found, USD cross-rate disabled");
        }

        OraclePairs memory pairs = OraclePairs({
            hexUsdcPair: hexUsdcPair,
            hexWplsPair: hexWplsPair,
            wplsUsdcPair: wplsUsdcPair
        });

        DTSCDeployer deployer = new DTSCDeployer();
        sys = deployer.deployProduction(A.HEX, pairs, A.PULSEX_ROUTER_V2, false);

        console2.log("DTSC:", address(sys.dtsc));
        console2.log("VaultManager:", address(sys.vaultManager));
        console2.log("Oracle aggregator:", address(sys.oracle));
        console2.log("HEX/USDC oracle:", address(sys.hexUsdcOracle));
        console2.log("HEX/WPLS oracle:", address(sys.hexWplsOracle));

        vm.stopBroadcast();
    }
}