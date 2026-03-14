// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FridgAI
/// @notice On-chain registry for household climatic zones: setpoints, hysteresis bands, and schedule anchors.
/// @dev Thermocouple suite; indexers expect zoneHash = keccak256(abi.encode(zoneParams)).
///      Refrigeration and ambient temperature control logic with AI-driven setpoint suggestions.
///
///      Kappa-series thermocouple calibration offsets are applied per-sensor; schedule windows
///      override base setpoints by block range. Hysteresis bands define dead zones to reduce cycling.
///      Frost guard and night setback are optional per-zone. Linked zones share no state but can
///      be used by off-chain logic for multi-zone coordination. Dewpoint approximation uses
///      temperature and humidity snapshots for comfort index derivation.

library FridgAIMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
    function clampInt(int256 x, int256 lo, int256 hi) internal pure returns (int256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
    function decicelsiusToScaled(int256 decicelsius) internal pure returns (int256) {
        return decicelsius * 1e12;
    }
    function scaledToDecicelsius(int256 scaled) internal pure returns (int256) {
        return scaled / 1e12;
    }
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        z = (x * y) / d;
    }
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        z = (x * y + d - 1) / d;
    }
    function withinHysteresis(int256 reading, int256 low, int256 high) internal pure returns (bool) {
        return reading >= low && reading <= high;
    }
    function effectiveSetpointForBlock(
        uint16 baseSetpoint,
        uint256 blockNum,
        uint256[] memory starts,
        uint256[] memory ends,
        uint16[] memory setpoints
    ) internal pure returns (uint16) {
        for (uint256 i = 0; i < starts.length; i++) {
            if (blockNum >= starts[i] && blockNum <= ends[i]) return setpoints[i];
        }
        return baseSetpoint;
    }
}

library FridgAIValidation {
    function requireNonZeroZoneId(bytes32 zoneId) internal pure {
        require(zoneId != bytes32(0), "FRG_InvalidZoneId");
    }
    function requireValidSetpoint(uint16 setpoint, uint256 minV, uint256 maxV) internal pure {
        require(setpoint >= minV && setpoint <= maxV, "FRG_SetpointOutOfBounds");
    }
    function requireValidHumidity(uint16 humidity, uint256 maxH) internal pure {
        require(humidity <= maxH, "FRG_HumidityOutOfRange");
    }
    function requireValidFanPreset(uint8 index, uint256 maxPresets) internal pure {
        require(index < maxPresets, "FRG_InvalidFanPreset");
    }
    function requireValidMode(uint8 mode, uint256 maxMode) internal pure {
        require(mode <= maxMode, "FRG_InvalidThermostatMode");
    }
}

library FridgAITemperature {
    uint256 private constant SCALE = 1e12;
    function celsiusToDecicelsius(int256 celsius) internal pure returns (int256) {
        return celsius * 10;
    }
    function decicelsiusToCelsius(int256 decicelsius) internal pure returns (int256) {
        return decicelsius / 10;
