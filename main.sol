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
    error FRG_BandIndexOutOfRange();
    error FRG_AlreadyInitialized();
    error FRG_InvalidFee();
    error FRG_SetpointOutOfBounds();
    error FRG_InvalidScheduleWindow();
    error FRG_HysteresisBandInvalid();
    error FRG_CalibrationOutOfRange();
    error FRG_HumidityOutOfRange();
    error FRG_InvalidFanPreset();
    error FRG_LabelTooLong();
    error FRG_CooldownActive();
    error FRG_BatchSizeZero();
    error FRG_BatchSizeTooLarge();
    error FRG_InvalidThermostatMode();
    error FRG_ZoneAlreadyLinked();
    error FRG_ZoneNotLinked();
    error FRG_CannotLinkSelf();
    error FRG_SensorIndexOutOfRange();
    error FRG_SetbackOutOfBounds();
    error FRG_InvalidNonce();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant FRG_VERSION = 12;
    uint256 public constant MAX_LABEL_LENGTH = 64;
    uint256 public constant MAX_BATCH_ZONES = 50;
    uint256 public constant MAX_BATCH_READINGS = 200;
    uint256 public constant THERMOSTAT_MODE_OFF = 0;
    uint256 public constant THERMOSTAT_MODE_COOL = 1;
    uint256 public constant THERMOSTAT_MODE_HEAT = 2;
    uint256 public constant THERMOSTAT_MODE_AUTO = 3;
    uint256 public constant MAX_FAN_PRESETS = 8;
    uint256 public constant MAX_HUMIDITY_PERCENT = 100;
    uint256 public constant CALIBRATION_OFFSET_MAX = 1e15;
    uint256 public constant MAX_LINKED_ZONES = 16;
    uint256 public constant MAX_READINGS_PER_ZONE = 60000;
    uint256 public constant MAX_HYSTERESIS_BANDS = 2500;
    uint256 public constant TEMP_SCALE_FACTOR = 1e12;
    uint256 public constant MIN_SETPOINT_DECICELSIUS = 0;
    uint256 public constant MAX_SETPOINT_DECICELSIUS = 500;
    bytes32 public constant FRG_DOMAIN = keccak256("FridgAI.Climate.v12");
    uint256 public constant MAX_SCHEDULE_WINDOWS_PER_ZONE = 96;
    uint256 public constant DEFROST_MAX_DURATION = 3600;

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable climateHub;
    address public immutable feeCollector;
    uint256 public immutable anchorFeeWei;
    address public immutable fallbackTreasury;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    address public climateCurator;
    bool private _paused;
    uint256 private _guard;
    uint256 private _nextZoneId;
    mapping(bytes32 => Zone) private _zones;
    mapping(bytes32 => bool) private _archived;
    mapping(bytes32 => uint32) private _readingCount;
    mapping(bytes32 => uint32) private _bandCount;
    mapping(bytes32 => ScheduleWindow[]) private _schedules;
    mapping(bytes32 => uint256) private _defrostLastAt;
    mapping(address => uint256) private _operatorNonce;
    mapping(bytes32 => int256) private _calibrationOffset;
    mapping(bytes32 => uint16) private _humiditySnapshot;
    mapping(bytes32 => uint256) private _cooldownUntilBlock;
    mapping(bytes32 => uint8) private _thermostatMode;
    mapping(bytes32 => bool) private _frostGuardEnabled;
    mapping(bytes32 => uint16) private _nightSetbackDecicelsius;
    mapping(bytes32 => uint16) private _daySetforwardDecicelsius;
    mapping(bytes32 => string) private _zoneLabel;
    mapping(bytes32 => bytes32[]) private _linkedZones;
    mapping(bytes32 => mapping(bytes32 => bool)) private _linkExists;
    mapping(bytes32 => mapping(uint8 => uint8)) private _fanPresetSpeed;
    mapping(bytes32 => mapping(uint32 => int256)) private _sensorCalibration;

    struct Zone {
        bytes32 zoneHash;
        uint16 setpointDecicelsius;
        uint64 createdAt;
        bool coolingPreferred;
        int256 lastSuggestedSetpoint;
    }

    struct ScheduleWindow {
        uint256 startBlock;
        uint256 endBlock;
        uint16 setpointDecicelsius;
    }

    struct HysteresisBand {
        int256 lowThresholdScaled;
        int256 highThresholdScaled;
        uint32 bandIndex;
    }

    mapping(bytes32 => mapping(uint32 => HysteresisBand)) private _bands;
    mapping(bytes32 => mapping(uint32 => SetpointReading)) private _readings;

    struct SetpointReading {
        int256 tempScaled;
        bytes32 sensorRoot;
        uint64 recordedAt;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyClimateCurator() {
        if (msg.sender != climateCurator) revert FRG_NotClimateCurator();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert FRG_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_guard == 1) revert FRG_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        climateHub = address(0xFa3c8E1b7D4f0A2e6C9b5D8f1a4E7c0B3F6d9A2e5);
        feeCollector = address(0x2E7b0D4f8A1c6E9b3F0d5A8c2E6f1B4a7D9c0E3F6);
        fallbackTreasury = address(0xC1a5E8f2B6d9A3c0E7f4B1d8C5a2E9b6F0c3D7e1);
        climateCurator = address(0x6B9e2D5f8A1c4E7b0D3f6A9c2E5b8F1d4C7a0E3B6);
        anchorFeeWei = 0.001 ether;
        _nextZoneId = 1;
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: ZONE LIFECYCLE
    // -------------------------------------------------------------------------

    function registerZone(
        bytes32 zoneId,
        uint16 setpointDecicelsius,
        bytes32 zoneHash,
        bool coolingPreferred
    ) external payable whenNotPaused nonReentrant {
        if (zoneId == bytes32(0)) revert FRG_InvalidZoneId();
        if (zoneHash == bytes32(0)) revert FRG_InvalidZoneHash();
        if (msg.value < anchorFeeWei) revert FRG_AnchorFeeRequired();
        if (setpointDecicelsius < MIN_SETPOINT_DECICELSIUS || setpointDecicelsius > MAX_SETPOINT_DECICELSIUS) revert FRG_SetpointOutOfBounds();
        if (_zones[zoneId].createdAt != 0) revert FRG_AlreadyInitialized();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();

        _zones[zoneId] = Zone({
            zoneHash: zoneHash,
            setpointDecicelsius: setpointDecicelsius,
            createdAt: uint64(block.timestamp),
            coolingPreferred: coolingPreferred,
            lastSuggestedSetpoint: 0
        });

        (bool sent,) = feeCollector.call{value: anchorFeeWei}("");
        if (!sent) revert FRG_TransferFailed();
        if (msg.value > anchorFeeWei) {
            (bool refund,) = msg.sender.call{value: msg.value - anchorFeeWei}("");
            if (!refund) revert FRG_TransferFailed();
        }

        emit ZoneRegistered(zoneId, msg.sender, setpointDecicelsius, zoneHash, block.timestamp);
    }

    function recordSetpointReading(
        bytes32 zoneId,
        uint32 readingIndex,
        int256 tempScaled,
        bytes32 sensorRoot
    ) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (readingIndex >= MAX_READINGS_PER_ZONE) revert FRG_ReadingIndexOutOfRange();

        _readings[zoneId][readingIndex] = SetpointReading({
            tempScaled: tempScaled,
            sensorRoot: sensorRoot,
            recordedAt: uint64(block.timestamp)
        });
        _readingCount[zoneId] = readingIndex + 1 > _readingCount[zoneId] ? readingIndex + 1 : _readingCount[zoneId];

        emit SetpointRecorded(zoneId, readingIndex, tempScaled, sensorRoot, block.timestamp);
    }

    function anchorHysteresisBand(
        bytes32 zoneId,
        uint32 bandIndex,
        int256 lowThresholdScaled,
        int256 highThresholdScaled
    ) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (bandIndex >= MAX_HYSTERESIS_BANDS) revert FRG_BandIndexOutOfRange();
        if (lowThresholdScaled >= highThresholdScaled) revert FRG_HysteresisBandInvalid();

        _bands[zoneId][bandIndex] = HysteresisBand({
            lowThresholdScaled: lowThresholdScaled,
            highThresholdScaled: highThresholdScaled,
            bandIndex: bandIndex
        });
        _bandCount[zoneId] = bandIndex + 1 > _bandCount[zoneId] ? bandIndex + 1 : _bandCount[zoneId];

        bytes32 bandHash = keccak256(abi.encode(lowThresholdScaled, highThresholdScaled, bandIndex));
        emit HysteresisAnchored(zoneId, bandIndex, bandHash, block.timestamp);
    }

    function bindScheduleWindow(
        bytes32 zoneId,
        uint256 startBlock,
        uint256 endBlock,
        uint16 setpointDecicelsius
    ) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (startBlock >= endBlock) revert FRG_InvalidScheduleWindow();
        if (setpointDecicelsius < MIN_SETPOINT_DECICELSIUS || setpointDecicelsius > MAX_SETPOINT_DECICELSIUS) revert FRG_SetpointOutOfBounds();

        ScheduleWindow[] storage windows = _schedules[zoneId];
        if (windows.length >= MAX_SCHEDULE_WINDOWS_PER_ZONE) revert FRG_InvalidScheduleWindow();
        windows.push(ScheduleWindow({ startBlock: startBlock, endBlock: endBlock, setpointDecicelsius: setpointDecicelsius }));

        emit ScheduleBound(zoneId, startBlock, endBlock, block.timestamp);
    }

    function applySetpointSuggestion(bytes32 zoneId, int256 suggestedDecicelsius) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (suggestedDecicelsius < 0 || suggestedDecicelsius > int256(MAX_SETPOINT_DECICELSIUS)) revert FRG_SetpointOutOfBounds();

        _zones[zoneId].setpointDecicelsius = uint16(uint256(int256(suggestedDecicelsius)));
        _zones[zoneId].lastSuggestedSetpoint = suggestedDecicelsius;
        emit SetpointSuggestionApplied(zoneId, suggestedDecicelsius, msg.sender);
    }

    function setAmbientOverride(bytes32 zoneId, bool coolingActive) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        _zones[zoneId].coolingPreferred = coolingActive;
        emit AmbientOverride(zoneId, coolingActive, block.timestamp);
    }

    function logDefrostCycle(bytes32 zoneId, uint256 durationSeconds) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (durationSeconds > DEFROST_MAX_DURATION) revert FRG_InvalidScheduleWindow();
        _defrostLastAt[zoneId] = block.timestamp;
        emit DefrostCycleLogged(zoneId, durationSeconds, block.timestamp);
    }

    function archiveZone(bytes32 zoneId) external onlyClimateCurator {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        _archived[zoneId] = true;
        emit ZoneArchived(zoneId, msg.sender, block.timestamp);
    }

    function setCalibrationOffset(bytes32 zoneId, int256 offsetScaled) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (offsetScaled > int256(CALIBRATION_OFFSET_MAX) || offsetScaled < -int256(CALIBRATION_OFFSET_MAX)) revert FRG_CalibrationOutOfRange();
        _calibrationOffset[zoneId] = offsetScaled;
        emit CalibrationOffsetSet(zoneId, offsetScaled, block.timestamp);
    }

    function recordHumiditySnapshot(bytes32 zoneId, uint16 humidityPercent) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (humidityPercent > MAX_HUMIDITY_PERCENT) revert FRG_HumidityOutOfRange();
        _humiditySnapshot[zoneId] = humidityPercent;
        emit HumiditySnapshot(zoneId, humidityPercent, block.timestamp);
    }

    function setFanPreset(bytes32 zoneId, uint8 presetIndex, uint8 speedPercent) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (presetIndex >= MAX_FAN_PRESETS) revert FRG_InvalidFanPreset();
        if (speedPercent > 100) revert FRG_InvalidFanPreset();
        _fanPresetSpeed[zoneId][presetIndex] = speedPercent;
        emit FanPresetBound(zoneId, presetIndex, speedPercent, block.timestamp);
    }

    function setZoneLabel(bytes32 zoneId, string calldata label) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (bytes(label).length > MAX_LABEL_LENGTH) revert FRG_LabelTooLong();
        _zoneLabel[zoneId] = label;
        emit ZoneLabelSet(zoneId, label, block.timestamp);
    }

    function startCooldownWindow(bytes32 zoneId, uint256 durationBlocks) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        _cooldownUntilBlock[zoneId] = block.number + durationBlocks;
        emit CooldownWindowStarted(zoneId, block.number + durationBlocks, block.timestamp);
    }

    function endCooldownWindow(bytes32 zoneId) external onlyClimateCurator {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        _cooldownUntilBlock[zoneId] = 0;
        emit CooldownWindowEnded(zoneId, block.timestamp);
    }

    function setThermostatMode(bytes32 zoneId, uint8 mode) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (mode > THERMOSTAT_MODE_AUTO) revert FRG_InvalidThermostatMode();
        _thermostatMode[zoneId] = mode;
        emit ThermostatModeSet(zoneId, mode, block.timestamp);
    }

    function setFrostGuard(bytes32 zoneId, bool enabled) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        _frostGuardEnabled[zoneId] = enabled;
        emit FrostGuardToggled(zoneId, enabled, block.timestamp);
    }

    function setNightSetback(bytes32 zoneId, uint16 setbackDecicelsius) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (setbackDecicelsius > MAX_SETPOINT_DECICELSIUS) revert FRG_SetbackOutOfBounds();
        _nightSetbackDecicelsius[zoneId] = setbackDecicelsius;
        emit NightSetbackApplied(zoneId, setbackDecicelsius, block.timestamp);
    }

    function setDaySetforward(bytes32 zoneId, uint16 setforwardDecicelsius) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (setforwardDecicelsius > MAX_SETPOINT_DECICELSIUS) revert FRG_SetbackOutOfBounds();
        _daySetforwardDecicelsius[zoneId] = setforwardDecicelsius;
        emit DaySetforwardApplied(zoneId, setforwardDecicelsius, block.timestamp);
    }

    function recordSensorCalibration(bytes32 zoneId, uint32 sensorIndex, int256 correctionScaled) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (sensorIndex >= MAX_READINGS_PER_ZONE) revert FRG_SensorIndexOutOfRange();
        _sensorCalibration[zoneId][sensorIndex] = correctionScaled;
        emit SensorCalibrationRecorded(zoneId, sensorIndex, correctionScaled, block.timestamp);
    }

    function linkZones(bytes32 zoneA, bytes32 zoneB) external onlyClimateCurator whenNotPaused {
        if (zoneA == zoneB) revert FRG_CannotLinkSelf();
        if (_zones[zoneA].createdAt == 0 || _zones[zoneB].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneA] || _archived[zoneB]) revert FRG_ZoneAlreadyArchived();
        if (_linkExists[zoneA][zoneB]) revert FRG_ZoneAlreadyLinked();
        bytes32[] storage linksA = _linkedZones[zoneA];
        if (linksA.length >= MAX_LINKED_ZONES) revert FRG_InvalidScheduleWindow();
        linksA.push(zoneB);
        _linkExists[zoneA][zoneB] = true;
        _linkedZones[zoneB].push(zoneA);
        _linkExists[zoneB][zoneA] = true;
        emit ZoneLinked(zoneA, zoneB, block.timestamp);
    }

    function unlinkZones(bytes32 zoneA, bytes32 zoneB) external onlyClimateCurator {
        if (!_linkExists[zoneA][zoneB]) revert FRG_ZoneNotLinked();
        _removeLink(zoneA, zoneB);
        _removeLink(zoneB, zoneA);
        _linkExists[zoneA][zoneB] = false;
        _linkExists[zoneB][zoneA] = false;
        emit ZoneUnlinked(zoneA, zoneB, block.timestamp);
    }

    function _removeLink(bytes32 zoneId, bytes32 other) private {
        bytes32[] storage links = _linkedZones[zoneId];
        for (uint256 i = 0; i < links.length; i++) {
            if (links[i] == other) {
                links[i] = links[links.length - 1];
                links.pop();
                return;
            }
        }
    }

    function emergencySetpointOverride(bytes32 zoneId, uint16 setpointDecicelsius) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        if (setpointDecicelsius < MIN_SETPOINT_DECICELSIUS || setpointDecicelsius > MAX_SETPOINT_DECICELSIUS) revert FRG_SetpointOutOfBounds();
        _zones[zoneId].setpointDecicelsius = setpointDecicelsius;
        emit EmergencySetpointOverride(zoneId, setpointDecicelsius, msg.sender, block.timestamp);
    }

    function incrementOperatorNonce() external whenNotPaused {
        _operatorNonce[msg.sender] += 1;
        emit OperatorNonceIncremented(msg.sender, _operatorNonce[msg.sender], block.timestamp);
    }

    function batchRegisterZones(
        bytes32[] calldata zoneIds,
        uint16[] calldata setpointsDecicelsius,
        bytes32[] calldata zoneHashes,
        bool[] calldata coolingPreferred
    ) external payable whenNotPaused nonReentrant {
        uint256 n = zoneIds.length;
        if (n == 0) revert FRG_BatchSizeZero();
        if (n > MAX_BATCH_ZONES) revert FRG_BatchSizeTooLarge();
        if (n != setpointsDecicelsius.length || n != zoneHashes.length || n != coolingPreferred.length) revert FRG_ReadingCountMismatch();
        uint256 totalFee = anchorFeeWei * n;
        if (msg.value < totalFee) revert FRG_AnchorFeeRequired();
        for (uint256 i = 0; i < n; i++) {
            bytes32 zid = zoneIds[i];
            if (zid == bytes32(0)) revert FRG_InvalidZoneId();
            if (zoneHashes[i] == bytes32(0)) revert FRG_InvalidZoneHash();
            if (setpointsDecicelsius[i] < MIN_SETPOINT_DECICELSIUS || setpointsDecicelsius[i] > MAX_SETPOINT_DECICELSIUS) revert FRG_SetpointOutOfBounds();
            if (_zones[zid].createdAt != 0) revert FRG_AlreadyInitialized();
            if (_archived[zid]) revert FRG_ZoneAlreadyArchived();
            _zones[zid] = Zone({
                zoneHash: zoneHashes[i],
                setpointDecicelsius: setpointsDecicelsius[i],
                createdAt: uint64(block.timestamp),
                coolingPreferred: coolingPreferred[i],
                lastSuggestedSetpoint: 0
            });
            emit ZoneRegistered(zid, msg.sender, setpointsDecicelsius[i], zoneHashes[i], block.timestamp);
        }
        (bool sent,) = feeCollector.call{value: totalFee}("");
        if (!sent) revert FRG_TransferFailed();
        if (msg.value > totalFee) {
            (bool refund,) = msg.sender.call{value: msg.value - totalFee}("");
            if (!refund) revert FRG_TransferFailed();
        }
        emit BatchZonesRegistered(n, msg.sender, block.timestamp);
    }

    function batchRecordSetpointReadings(
        bytes32 zoneId,
        uint32 startIndex,
        int256[] calldata tempsScaled,
        bytes32[] calldata sensorRoots
    ) external onlyClimateCurator whenNotPaused {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (_archived[zoneId]) revert FRG_ZoneAlreadyArchived();
        uint256 n = tempsScaled.length;
        if (n == 0) revert FRG_BatchSizeZero();
        if (n > MAX_BATCH_READINGS) revert FRG_BatchSizeTooLarge();
        if (n != sensorRoots.length) revert FRG_ReadingCountMismatch();
        for (uint256 i = 0; i < n; i++) {
            uint32 idx = startIndex + uint32(i);
            if (idx >= MAX_READINGS_PER_ZONE) revert FRG_ReadingIndexOutOfRange();
            _readings[zoneId][idx] = SetpointReading({
                tempScaled: tempsScaled[i],
                sensorRoot: sensorRoots[i],
                recordedAt: uint64(block.timestamp)
            });
        }
        if (startIndex + uint32(n) > _readingCount[zoneId]) _readingCount[zoneId] = startIndex + uint32(n);
        emit BatchReadingsRecorded(zoneId, startIndex, uint32(n), block.timestamp);
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: VIEW
    // -------------------------------------------------------------------------

    function getZone(bytes32 zoneId) external view returns (
        bytes32 zoneHash,
        uint16 setpointDecicelsius,
        uint64 createdAt,
        bool coolingPreferred,
        int256 lastSuggestedSetpoint
    ) {
        Zone storage z = _zones[zoneId];
        if (z.createdAt == 0) revert FRG_ZoneNotFound();
        return (z.zoneHash, z.setpointDecicelsius, z.createdAt, z.coolingPreferred, z.lastSuggestedSetpoint);
    }

    function getSetpointReading(bytes32 zoneId, uint32 readingIndex) external view returns (
        int256 tempScaled,
        bytes32 sensorRoot,
        uint64 recordedAt
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (readingIndex >= _readingCount[zoneId]) revert FRG_ReadingIndexOutOfRange();
        SetpointReading storage r = _readings[zoneId][readingIndex];
        return (r.tempScaled, r.sensorRoot, r.recordedAt);
    }

    function getHysteresisBand(bytes32 zoneId, uint32 bandIndex) external view returns (
        int256 lowThresholdScaled,
        int256 highThresholdScaled,
        uint32 bandIndexOut
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (bandIndex >= _bandCount[zoneId]) revert FRG_BandIndexOutOfRange();
        HysteresisBand storage b = _bands[zoneId][bandIndex];
        return (b.lowThresholdScaled, b.highThresholdScaled, b.bandIndex);
    }

    function getScheduleWindowCount(bytes32 zoneId) external view returns (uint256) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return _schedules[zoneId].length;
    }

    function getScheduleWindow(bytes32 zoneId, uint256 index) external view returns (
        uint256 startBlock,
        uint256 endBlock,
        uint16 setpointDecicelsius
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        ScheduleWindow[] storage windows = _schedules[zoneId];
        if (index >= windows.length) revert FRG_ReadingIndexOutOfRange();
        ScheduleWindow storage w = windows[index];
        return (w.startBlock, w.endBlock, w.setpointDecicelsius);
    }

    function readingCount(bytes32 zoneId) external view returns (uint32) {
        return _readingCount[zoneId];
    }

    function bandCount(bytes32 zoneId) external view returns (uint32) {
        return _bandCount[zoneId];
    }

    function isArchived(bytes32 zoneId) external view returns (bool) {
        return _archived[zoneId];
    }

    function defrostLastAt(bytes32 zoneId) external view returns (uint256) {
        return _defrostLastAt[zoneId];
    }

    function nextZoneId() external view returns (uint256) {
        return _nextZoneId;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function getCalibrationOffset(bytes32 zoneId) external view returns (int256) {
        return _calibrationOffset[zoneId];
    }

    function getHumiditySnapshot(bytes32 zoneId) external view returns (uint16) {
        return _humiditySnapshot[zoneId];
    }

    function getCooldownUntilBlock(bytes32 zoneId) external view returns (uint256) {
        return _cooldownUntilBlock[zoneId];
    }

    function getThermostatMode(bytes32 zoneId) external view returns (uint8) {
        return _thermostatMode[zoneId];
    }

    function getFrostGuardEnabled(bytes32 zoneId) external view returns (bool) {
        return _frostGuardEnabled[zoneId];
    }

    function getNightSetback(bytes32 zoneId) external view returns (uint16) {
        return _nightSetbackDecicelsius[zoneId];
    }

    function getDaySetforward(bytes32 zoneId) external view returns (uint16) {
        return _daySetforwardDecicelsius[zoneId];
    }

    function getZoneLabel(bytes32 zoneId) external view returns (string memory) {
        return _zoneLabel[zoneId];
    }

    function getLinkedZoneCount(bytes32 zoneId) external view returns (uint256) {
        return _linkedZones[zoneId].length;
    }

    function getLinkedZone(bytes32 zoneId, uint256 index) external view returns (bytes32) {
        bytes32[] storage links = _linkedZones[zoneId];
        if (index >= links.length) revert FRG_ReadingIndexOutOfRange();
        return links[index];
    }

    function areZonesLinked(bytes32 zoneA, bytes32 zoneB) external view returns (bool) {
        return _linkExists[zoneA][zoneB];
    }

    function getFanPresetSpeed(bytes32 zoneId, uint8 presetIndex) external view returns (uint8) {
        return _fanPresetSpeed[zoneId][presetIndex];
    }

    function getSensorCalibration(bytes32 zoneId, uint32 sensorIndex) external view returns (int256) {
        return _sensorCalibration[zoneId][sensorIndex];
    }

    function operatorNonce(address account) external view returns (uint256) {
        return _operatorNonce[account];
    }

    function isInCooldown(bytes32 zoneId) external view returns (bool) {
        return block.number < _cooldownUntilBlock[zoneId];
    }

    function getEffectiveSetpointAtBlock(bytes32 zoneId, uint256 blockNum) external view returns (uint16) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        Zone storage z = _zones[zoneId];
        ScheduleWindow[] storage windows = _schedules[zoneId];
        uint256 len = windows.length;
        for (uint256 i = 0; i < len; i++) {
            if (blockNum >= windows[i].startBlock && blockNum <= windows[i].endBlock) {
                return windows[i].setpointDecicelsius;
            }
        }
        return z.setpointDecicelsius;
    }

    function getEffectiveSetpointNow(bytes32 zoneId) external view returns (uint16) {
        return this.getEffectiveSetpointAtBlock(zoneId, block.number);
    }

    function getCorrectedReading(bytes32 zoneId, uint32 readingIndex) external view returns (int256) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (readingIndex >= _readingCount[zoneId]) revert FRG_ReadingIndexOutOfRange();
        SetpointReading storage r = _readings[zoneId][readingIndex];
        int256 cal = _sensorCalibration[zoneId][readingIndex];
        return r.tempScaled + cal;
    }

    function getZoneFull(bytes32 zoneId) external view returns (
        bytes32 zoneHash,
        uint16 setpointDecicelsius,
        uint64 createdAt,
        bool coolingPreferred,
        int256 lastSuggestedSetpoint,
        int256 calibrationOffset,
        uint16 humiditySnapshot,
        uint8 thermostatMode,
        bool frostGuardEnabled,
        string memory label
    ) {
        Zone storage z = _zones[zoneId];
        if (z.createdAt == 0) revert FRG_ZoneNotFound();
        return (
            z.zoneHash,
            z.setpointDecicelsius,
            z.createdAt,
            z.coolingPreferred,
            z.lastSuggestedSetpoint,
            _calibrationOffset[zoneId],
            _humiditySnapshot[zoneId],
            _thermostatMode[zoneId],
            _frostGuardEnabled[zoneId],
            _zoneLabel[zoneId]
        );
    }

    function getZoneSetpointAndMode(bytes32 zoneId) external view returns (uint16 setpoint, uint8 mode) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return (_zones[zoneId].setpointDecicelsius, _thermostatMode[zoneId]);
    }

    function getZoneCreatedAt(bytes32 zoneId) external view returns (uint64) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return _zones[zoneId].createdAt;
    }

    function getZoneCoolingPreferred(bytes32 zoneId) external view returns (bool) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return _zones[zoneId].coolingPreferred;
    }

    function getZoneLastSuggestedSetpoint(bytes32 zoneId) external view returns (int256) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return _zones[zoneId].lastSuggestedSetpoint;
    }

    function getZoneHash(bytes32 zoneId) external view returns (bytes32) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        return _zones[zoneId].zoneHash;
    }

    function getReadingsRange(bytes32 zoneId, uint32 fromIndex, uint32 toIndex) external view returns (
        int256[] memory tempsScaled,
        bytes32[] memory sensorRoots,
        uint64[] memory recordedAts
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        uint32 count = _readingCount[zoneId];
        if (fromIndex >= count || toIndex >= count || fromIndex > toIndex) revert FRG_ReadingIndexOutOfRange();
        uint256 len = uint256(toIndex - fromIndex + 1);
        tempsScaled = new int256[](len);
        sensorRoots = new bytes32[](len);
        recordedAts = new uint64[](len);
        for (uint256 i = 0; i < len; i++) {
            SetpointReading storage r = _readings[zoneId][fromIndex + uint32(i)];
            tempsScaled[i] = r.tempScaled;
            sensorRoots[i] = r.sensorRoot;
            recordedAts[i] = r.recordedAt;
        }
    }

    function getBandsRange(bytes32 zoneId, uint32 fromIndex, uint32 toIndex) external view returns (
        int256[] memory lowThresholds,
        int256[] memory highThresholds,
        uint32[] memory bandIndices
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        uint32 count = _bandCount[zoneId];
        if (fromIndex >= count || toIndex >= count || fromIndex > toIndex) revert FRG_BandIndexOutOfRange();
        uint256 len = uint256(toIndex - fromIndex + 1);
        lowThresholds = new int256[](len);
        highThresholds = new int256[](len);
        bandIndices = new uint32[](len);
        for (uint256 i = 0; i < len; i++) {
            HysteresisBand storage b = _bands[zoneId][fromIndex + uint32(i)];
            lowThresholds[i] = b.lowThresholdScaled;
            highThresholds[i] = b.highThresholdScaled;
            bandIndices[i] = b.bandIndex;
        }
    }

    function getScheduleWindows(bytes32 zoneId) external view returns (
        uint256[] memory startBlocks,
        uint256[] memory endBlocks,
        uint16[] memory setpointsDecicelsius
    ) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        ScheduleWindow[] storage w = _schedules[zoneId];
        uint256 len = w.length;
        startBlocks = new uint256[](len);
        endBlocks = new uint256[](len);
        setpointsDecicelsius = new uint16[](len);
        for (uint256 i = 0; i < len; i++) {
            startBlocks[i] = w[i].startBlock;
            endBlocks[i] = w[i].endBlock;
            setpointsDecicelsius[i] = w[i].setpointDecicelsius;
        }
    }

    function getFanPresets(bytes32 zoneId) external view returns (uint8[] memory speeds) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        speeds = new uint8[](MAX_FAN_PRESETS);
        for (uint8 i = 0; i < MAX_FAN_PRESETS; i++) {
            speeds[i] = _fanPresetSpeed[zoneId][i];
        }
    }

    function getDewpointApprox(bytes32 zoneId) external view returns (int256 decicelsiusApprox) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        uint32 n = _readingCount[zoneId];
        if (n == 0) return 0;
        SetpointReading storage r = _readings[zoneId][n - 1];
        uint16 h = _humiditySnapshot[zoneId];
        return FridgAITemperature.dewpointApprox(r.tempScaled / int256(TEMP_SCALE_FACTOR), h);
    }

    function celsiusToDecicelsius(int256 celsius) external pure returns (int256) {
        return FridgAITemperature.celsiusToDecicelsius(celsius);
    }

    function decicelsiusToCelsius(int256 decicelsius) external pure returns (int256) {
        return FridgAITemperature.decicelsiusToCelsius(decicelsius);
    }

    function fahrenheitToDecicelsius(int256 fahrenheit) external pure returns (int256) {
        return FridgAITemperature.fahrenheitToDecicelsius(fahrenheit);
    }

    function decicelsiusToFahrenheit(int256 decicelsius) external pure returns (int256) {
        return FridgAITemperature.decicelsiusToFahrenheit(decicelsius);
    }

    function scaledToDecicelsiusPublic(int256 scaled) external pure returns (int256) {
        return FridgAITemperature.fromScaled(scaled);
    }

    function decicelsiusToScaledPublic(int256 decicelsius) external pure returns (int256) {
        return FridgAITemperature.toScaled(decicelsius);
    }

    function minUint(uint256 a, uint256 b) external pure returns (uint256) {
        return FridgAIMath.min(a, b);
    }

    function maxUint(uint256 a, uint256 b) external pure returns (uint256) {
        return FridgAIMath.max(a, b);
    }

    function clampUint(uint256 x, uint256 lo, uint256 hi) external pure returns (uint256) {
        return FridgAIMath.clamp(x, lo, hi);
    }

    function clampIntPublic(int256 x, int256 lo, int256 hi) external pure returns (int256) {
        return FridgAIMath.clampInt(x, lo, hi);
    }

    function absInt(int256 x) external pure returns (uint256) {
        return FridgAIMath.abs(x);
    }

    function saturatingSubPublic(uint256 a, uint256 b) external pure returns (uint256) {
        return FridgAIMath.saturatingSub(a, b);
    }

    function mulDivDownPublic(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FridgAIMath.mulDivDown(x, y, d);
    }

    function mulDivUpPublic(uint256 x, uint256 y, uint256 d) external pure returns (uint256) {
        return FridgAIMath.mulDivUp(x, y, d);
    }

    function domainSeparator() external pure returns (bytes32) {
        return FRG_DOMAIN;
    }

    function version() external pure returns (uint256) {
        return FRG_VERSION;
    }

    function maxReadingsPerZone() external pure returns (uint256) {
        return MAX_READINGS_PER_ZONE;
    }

    function maxHysteresisBands() external pure returns (uint256) {
        return MAX_HYSTERESIS_BANDS;
    }

    function tempScaleFactor() external pure returns (uint256) {
        return TEMP_SCALE_FACTOR;
    }

    function minSetpointDecicelsius() external pure returns (uint256) {
        return MIN_SETPOINT_DECICELSIUS;
    }

    function maxSetpointDecicelsius() external pure returns (uint256) {
        return MAX_SETPOINT_DECICELSIUS;
    }

    function maxScheduleWindowsPerZone() external pure returns (uint256) {
        return MAX_SCHEDULE_WINDOWS_PER_ZONE;
    }

    function defrostMaxDuration() external pure returns (uint256) {
        return DEFROST_MAX_DURATION;
    }

    function maxLabelLength() external pure returns (uint256) {
        return MAX_LABEL_LENGTH;
    }

    function maxBatchZones() external pure returns (uint256) {
        return MAX_BATCH_ZONES;
    }

    function maxBatchReadings() external pure returns (uint256) {
        return MAX_BATCH_READINGS;
    }

    function thermostatModeOff() external pure returns (uint256) {
        return THERMOSTAT_MODE_OFF;
    }

    function thermostatModeCool() external pure returns (uint256) {
        return THERMOSTAT_MODE_COOL;
    }

    function thermostatModeHeat() external pure returns (uint256) {
        return THERMOSTAT_MODE_HEAT;
    }

    function thermostatModeAuto() external pure returns (uint256) {
        return THERMOSTAT_MODE_AUTO;
    }

    function maxFanPresets() external pure returns (uint256) {
        return MAX_FAN_PRESETS;
    }

    function maxHumidityPercent() external pure returns (uint256) {
        return MAX_HUMIDITY_PERCENT;
    }

    function calibrationOffsetMax() external pure returns (uint256) {
        return CALIBRATION_OFFSET_MAX;
    }

    function maxLinkedZones() external pure returns (uint256) {
        return MAX_LINKED_ZONES;
    }

    function getImmutableAddresses() external view returns (
        address hub,
        address collector,
        address treasury
    ) {
        return (climateHub, feeCollector, fallbackTreasury);
    }

    function getCurator() external view returns (address) {
        return climateCurator;
    }

    function getAnchorFeeWei() external view returns (uint256) {
        return anchorFeeWei;
    }

    function getZoneBatch(bytes32[] calldata zoneIds) external view returns (
        bytes32[] memory zoneHashes,
        uint16[] memory setpoints,
        uint64[] memory createdAts,
        bool[] memory coolingPreferred,
        int256[] memory lastSuggested
    ) {
        uint256 n = zoneIds.length;
        zoneHashes = new bytes32[](n);
        setpoints = new uint16[](n);
        createdAts = new uint64[](n);
        coolingPreferred = new bool[](n);
        lastSuggested = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            Zone storage z = _zones[zoneIds[i]];
            if (z.createdAt != 0) {
                zoneHashes[i] = z.zoneHash;
                setpoints[i] = z.setpointDecicelsius;
                createdAts[i] = z.createdAt;
                coolingPreferred[i] = z.coolingPreferred;
                lastSuggested[i] = z.lastSuggestedSetpoint;
            }
        }
    }

    function getZoneStatusBatch(bytes32[] calldata zoneIds) external view returns (
        bool[] memory exists,
        bool[] memory archived,
        bool[] memory inCooldown
    ) {
        uint256 n = zoneIds.length;
        exists = new bool[](n);
        archived = new bool[](n);
        inCooldown = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 zid = zoneIds[i];
            exists[i] = _zones[zid].createdAt != 0;
            archived[i] = _archived[zid];
            inCooldown[i] = block.number < _cooldownUntilBlock[zid];
        }
    }

    function getReadingCountsBatch(bytes32[] calldata zoneIds) external view returns (uint32[] memory counts) {
        uint256 n = zoneIds.length;
        counts = new uint32[](n);
        for (uint256 i = 0; i < n; i++) counts[i] = _readingCount[zoneIds[i]];
    }

    function getBandCountsBatch(bytes32[] calldata zoneIds) external view returns (uint32[] memory counts) {
        uint256 n = zoneIds.length;
        counts = new uint32[](n);
        for (uint256 i = 0; i < n; i++) counts[i] = _bandCount[zoneIds[i]];
    }

    function getEffectiveSetpointsNowBatch(bytes32[] calldata zoneIds) external view returns (uint16[] memory setpoints) {
        uint256 n = zoneIds.length;
        setpoints = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            bytes32 zid = zoneIds[i];
            if (_zones[zid].createdAt == 0) continue;
            setpoints[i] = this.getEffectiveSetpointNow(zid);
        }
    }

    function getCalibrationOffsetsBatch(bytes32[] calldata zoneIds) external view returns (int256[] memory offsets) {
        uint256 n = zoneIds.length;
        offsets = new int256[](n);
        for (uint256 i = 0; i < n; i++) offsets[i] = _calibrationOffset[zoneIds[i]];
    }

    function getHumiditySnapshotsBatch(bytes32[] calldata zoneIds) external view returns (uint16[] memory humidities) {
        uint256 n = zoneIds.length;
        humidities = new uint16[](n);
        for (uint256 i = 0; i < n; i++) humidities[i] = _humiditySnapshot[zoneIds[i]];
    }

    function getThermostatModesBatch(bytes32[] calldata zoneIds) external view returns (uint8[] memory modes) {
        uint256 n = zoneIds.length;
        modes = new uint8[](n);
        for (uint256 i = 0; i < n; i++) modes[i] = _thermostatMode[zoneIds[i]];
    }

    function getFrostGuardBatch(bytes32[] calldata zoneIds) external view returns (bool[] memory enabled) {
        uint256 n = zoneIds.length;
        enabled = new bool[](n);
        for (uint256 i = 0; i < n; i++) enabled[i] = _frostGuardEnabled[zoneIds[i]];
    }

    function getDefrostLastAtBatch(bytes32[] calldata zoneIds) external view returns (uint256[] memory timestamps) {
        uint256 n = zoneIds.length;
        timestamps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) timestamps[i] = _defrostLastAt[zoneIds[i]];
    }

    function computeZoneHash(bytes32 zoneId, uint16 setpoint, bool cooling, bytes32 extra) external pure returns (bytes32) {
        return keccak256(abi.encode(FRG_DOMAIN, zoneId, setpoint, cooling, extra));
    }

    function withinHysteresisForZone(bytes32 zoneId, uint32 bandIndex, int256 readingScaled) external view returns (bool) {
        if (_zones[zoneId].createdAt == 0) revert FRG_ZoneNotFound();
        if (bandIndex >= _bandCount[zoneId]) revert FRG_BandIndexOutOfRange();
        HysteresisBand storage b = _bands[zoneId][bandIndex];
        return FridgAIMath.withinHysteresis(readingScaled, b.lowThresholdScaled, b.highThresholdScaled);
    }

    function clampSetpoint(int256 decicelsius) external pure returns (uint16) {
        int256 c = FridgAIMath.clampInt(decicelsius, int256(uint256(MIN_SETPOINT_DECICELSIUS)), int256(uint256(MAX_SETPOINT_DECICELSIUS)));
        return uint16(uint256(c));
    }

    // -------------------------------------------------------------------------
    // EXTERNAL: ADMIN
    // -------------------------------------------------------------------------

    function setClimateCurator(address newCurator) external onlyClimateCurator {
        if (newCurator == address(0)) revert FRG_ZeroAddress();
        address prev = climateCurator;
        climateCurator = newCurator;
        emit ClimateCuratorUpdated(prev, newCurator);
    }

    function setPaused(bool p) external onlyClimateCurator {
        _paused = p;
    }

    function pullTreasury(address to, uint256 amountWei) external onlyClimateCurator nonReentrant {
        if (to == address(0)) revert FRG_ZeroAddress();
        (bool sent,) = to.call{value: amountWei}("");
        if (!sent) revert FRG_TransferFailed();
        emit TreasuryPull(to, amountWei, block.timestamp);
    }

    receive() external payable {}

    // -------------------------------------------------------------------------
    // INTERNAL HELPERS
    // -------------------------------------------------------------------------

    function _zoneExists(bytes32 zoneId) internal view returns (bool) {
        return _zones[zoneId].createdAt != 0;
    }

    function _zoneActive(bytes32 zoneId) internal view returns (bool) {
        return _zoneExists(zoneId) && !_archived[zoneId];
    }

    function _applyCalibration(int256 rawScaled, bytes32 zoneId, uint32 sensorIndex) internal view returns (int256) {
        int256 cal = _sensorCalibration[zoneId][sensorIndex];
        return rawScaled + cal;
    }

    function _effectiveSetpointWithSetback(bytes32 zoneId, bool useNightSetback) internal view returns (uint16) {
        Zone storage z = _zones[zoneId];
        if (useNightSetback && _nightSetbackDecicelsius[zoneId] > 0) {
            return FridgAIMath.min(uint256(z.setpointDecicelsius), uint256(_nightSetbackDecicelsius[zoneId]));
        }
        if (!useNightSetback && _daySetforwardDecicelsius[zoneId] > 0) {
            return FridgAIMath.max(uint256(z.setpointDecicelsius), uint256(_daySetforwardDecicelsius[zoneId]));
        }
        return z.setpointDecicelsius;
    }

    function _scheduleWindowCount(bytes32 zoneId) internal view returns (uint256) {
        return _schedules[zoneId].length;
    }

    function _getScheduleAt(bytes32 zoneId, uint256 index) internal view returns (
        uint256 startBlock,
        uint256 endBlock,
        uint16 setpointDecicelsius
    ) {
        ScheduleWindow[] storage w = _schedules[zoneId];
        require(index < w.length, "FRG_ReadingIndexOutOfRange");
        ScheduleWindow storage s = w[index];
        return (s.startBlock, s.endBlock, s.setpointDecicelsius);
    }

    function _readingCountForZone(bytes32 zoneId) internal view returns (uint32) {
        return _readingCount[zoneId];
    }

    function _bandCountForZone(bytes32 zoneId) internal view returns (uint32) {
        return _bandCount[zoneId];
    }

    function _isCooldownActive(bytes32 zoneId) internal view returns (bool) {
        return block.number < _cooldownUntilBlock[zoneId];
    }

    function _linkedCount(bytes32 zoneId) internal view returns (uint256) {
        return _linkedZones[zoneId].length;
    }

    function _getLinkedAt(bytes32 zoneId, uint256 index) internal view returns (bytes32) {
        return _linkedZones[zoneId][index];
    }

    function _hasLink(bytes32 a, bytes32 b) internal view returns (bool) {
        return _linkExists[a][b];
    }

    function _fanSpeed(bytes32 zoneId, uint8 presetIndex) internal view returns (uint8) {
        return _fanPresetSpeed[zoneId][presetIndex];
    }

    function _calibration(bytes32 zoneId) internal view returns (int256) {
        return _calibrationOffset[zoneId];
    }

    function _humidity(bytes32 zoneId) internal view returns (uint16) {
        return _humiditySnapshot[zoneId];
    }

    function _thermostatModeFor(bytes32 zoneId) internal view returns (uint8) {
        return _thermostatMode[zoneId];
    }

    function _frostGuard(bytes32 zoneId) internal view returns (bool) {
        return _frostGuardEnabled[zoneId];
    }

    function _nightSetback(bytes32 zoneId) internal view returns (uint16) {
        return _nightSetbackDecicelsius[zoneId];
    }

    function _daySetforward(bytes32 zoneId) internal view returns (uint16) {
        return _daySetforwardDecicelsius[zoneId];
    }

    function _label(bytes32 zoneId) internal view returns (string memory) {
        return _zoneLabel[zoneId];
    }

    function _defrostAt(bytes32 zoneId) internal view returns (uint256) {
        return _defrostLastAt[zoneId];
    }

    function _sensorCal(bytes32 zoneId, uint32 sensorIndex) internal view returns (int256) {
        return _sensorCalibration[zoneId][sensorIndex];
    }

    function getScheduleWindowCountPublic(bytes32 zoneId) external view returns (uint256) {
        return _schedules[zoneId].length;
    }

    function getLastReadingTemp(bytes32 zoneId) external view returns (int256 tempScaled, bool hasReading) {
        uint32 n = _readingCount[zoneId];
        if (n == 0) return (0, false);
        tempScaled = _readings[zoneId][n - 1].tempScaled;
        hasReading = true;
    }

    function getLastReadingSensorRoot(bytes32 zoneId) external view returns (bytes32 root, bool hasReading) {
        uint32 n = _readingCount[zoneId];
        if (n == 0) return (bytes32(0), false);
        root = _readings[zoneId][n - 1].sensorRoot;
        hasReading = true;
    }

    function getLastReadingRecordedAt(bytes32 zoneId) external view returns (uint64 at, bool hasReading) {
        uint32 n = _readingCount[zoneId];
        if (n == 0) return (0, false);
        at = _readings[zoneId][n - 1].recordedAt;
        hasReading = true;
    }

    function hasAnySchedule(bytes32 zoneId) external view returns (bool) {
        return _schedules[zoneId].length > 0;
    }

