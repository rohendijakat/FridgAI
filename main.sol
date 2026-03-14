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

