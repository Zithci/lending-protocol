// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LendingPool.sol";
import "../src/LendingVault.sol";
import "../src/mocks/MockWETH.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/mocks/MockOracle.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock tokens (for testnet)
        MockWETH weth = new MockWETH();
        MockUSDC usdc = new MockUSDC();

        // Deploy mock oracle - ETH/USD at $2000
        MockOracle oracle = new MockOracle(2000e8, 8, "ETH/USD");

        // Deploy vault
        LendingVault vault = new LendingVault(usdc);

        // Deploy lending pool
        LendingPool pool = new LendingPool(
            address(weth),
            address(usdc),
            address(oracle),
            address(vault)
        );

        // Connect vault to pool
        vault.setLendingPool(address(pool));

        vm.stopBroadcast();

        console.log("=== Deployed Addresses ===");
        console.log("WETH:", address(weth));
        console.log("USDC:", address(usdc));
        console.log("Oracle:", address(oracle));
        console.log("Vault:", address(vault));
        console.log("Pool:", address(pool));
    }
}
