    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.24;

    import "../interfaces/AggregatorV3Interface.sol";

    contract MockOracle is AggregatorV3Interface {
        int256 private _price;
        uint8 private _decimals;
        string private _description;
        uint256 private _updatedAt;

        constructor(int256 initialPrice, uint8 priceDecimals, string memory desc) {
            _price = initialPrice;
            _decimals = priceDecimals;
            _description = desc;
            _updatedAt = block.timestamp;
        }

        function setPrice(int256 newPrice) external {
            _price = newPrice;
            _updatedAt = block.timestamp;
        }

        function decimals() external view override returns (uint8) {
            return _decimals;
        }

        function description() external view override returns (string memory) {
            return _description;
        }

        function version() external pure override returns (uint256) {
            return 1;
        }

        function latestRoundData()
            external
            view
            override
            returns (
                uint80 roundId,
                int256 answer,
                uint256 startedAt,
                uint256 updatedAt,
                uint80 answeredInRound
            )
        {
            return (1, _price, _updatedAt, _updatedAt, 1);
        }
    }
