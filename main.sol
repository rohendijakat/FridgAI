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
    }
    function fahrenheitToDecicelsius(int256 fahrenheit) internal pure returns (int256) {
        return (fahrenheit - 32) * 5 / 9 * 10;
    }
    function decicelsiusToFahrenheit(int256 decicelsius) internal pure returns (int256) {
        return decicelsius * 9 / 50 + 32;
    }
    function toScaled(int256 decicelsius) internal pure returns (int256) {
        return decicelsius * int256(SCALE);
    }
    function fromScaled(int256 scaled) internal pure returns (int256) {
        return scaled / int256(SCALE);
    }
    function dewpointApprox(int256 tempDecicelsius, uint16 humidityPercent) internal pure returns (int256 decicelsiusApprox) {
        int256 t = decicelsiusToCelsius(tempDecicelsius);
        int256 h = int256(uint256(humidityPercent));
        if (h <= 0) return tempDecicelsius;
        int256 offset = (t * (100 - int256(uint256(humidityPercent))) * 10) / 1000;
        decicelsiusApprox = tempDecicelsius - offset;
    }
}

contract FridgAI {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event ZoneRegistered(
        bytes32 indexed zoneId,
        address indexed submitter,
        uint16 setpointDecicelsius,
        bytes32 zoneHash,
        uint256 anchoredAt
    );
    event SetpointRecorded(
        bytes32 indexed zoneId,
        uint32 indexed readingIndex,
        int256 tempScaled,
        bytes32 sensorRoot,
        uint256 recordedAt
    );
    event HysteresisAnchored(
        bytes32 indexed zoneId,
        uint32 bandIndex,
        bytes32 bandHash,
        uint256 anchoredAt
    );
    event ClimateCuratorUpdated(address indexed previousCurator, address indexed newCurator);
    event FeeCollectorUpdated(address indexed previousCollector, address indexed newCollector);
    event AnchorFeeSet(uint256 previousFeeWei, uint256 newFeeWei);
    event ZoneArchived(bytes32 indexed zoneId, address indexed archivedBy, uint256 atBlock);
    event TreasuryPull(address indexed to, uint256 amountWei, uint256 atBlock);
    event ScheduleBound(bytes32 indexed zoneId, uint256 windowStart, uint256 windowEnd, uint256 atBlock);
    event SetpointSuggestionApplied(bytes32 indexed zoneId, int256 suggestedDecicelsius, address indexed appliedBy);
    event AmbientOverride(bytes32 indexed zoneId, bool coolingActive, uint256 atBlock);
    event DefrostCycleLogged(bytes32 indexed zoneId, uint256 durationSeconds, uint256 atBlock);
    event CalibrationOffsetSet(bytes32 indexed zoneId, int256 offsetScaled, uint256 atBlock);
    event HumiditySnapshot(bytes32 indexed zoneId, uint16 humidityPercent, uint256 atBlock);
    event FanPresetBound(bytes32 indexed zoneId, uint8 presetIndex, uint8 speedPercent, uint256 atBlock);
    event ZoneLabelSet(bytes32 indexed zoneId, string label, uint256 atBlock);
    event CooldownWindowStarted(bytes32 indexed zoneId, uint256 untilBlock, uint256 atBlock);
    event CooldownWindowEnded(bytes32 indexed zoneId, uint256 atBlock);
    event BatchZonesRegistered(uint256 count, address indexed submitter, uint256 atBlock);
    event BatchReadingsRecorded(bytes32 indexed zoneId, uint32 startIndex, uint32 count, uint256 atBlock);
    event EmergencySetpointOverride(bytes32 indexed zoneId, uint16 setpointDecicelsius, address indexed by, uint256 atBlock);
    event ThermostatModeSet(bytes32 indexed zoneId, uint8 mode, uint256 atBlock);
    event FrostGuardToggled(bytes32 indexed zoneId, bool enabled, uint256 atBlock);
    event NightSetbackApplied(bytes32 indexed zoneId, uint16 setbackDecicelsius, uint256 atBlock);
    event DaySetforwardApplied(bytes32 indexed zoneId, uint16 setforwardDecicelsius, uint256 atBlock);
    event SensorCalibrationRecorded(bytes32 indexed zoneId, uint32 sensorIndex, int256 correctionScaled, uint256 atBlock);
    event ZoneLinked(bytes32 indexed zoneA, bytes32 indexed zoneB, uint256 atBlock);
    event ZoneUnlinked(bytes32 indexed zoneA, bytes32 indexed zoneB, uint256 atBlock);
    event OperatorNonceIncremented(address indexed operator, uint256 newNonce, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error FRG_NotClimateCurator();
    error FRG_ZeroAddress();
    error FRG_ZoneNotFound();
    error FRG_ZoneAlreadyArchived();
    error FRG_ReadingIndexOutOfRange();
    error FRG_InvalidZoneId();
    error FRG_InvalidZoneHash();
    error FRG_AnchorFeeRequired();
    error FRG_TransferFailed();
    error FRG_Reentrancy();
    error FRG_Paused();
    error FRG_ReadingCountMismatch();
