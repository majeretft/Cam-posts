/**
  Heidenhain post processor configuration.
*/

description = "24K40 Heidenhain TNC 151";
vendor = "VTO ltd.";
vendorUrl = "hozpm@mail.ru";
legal = "Copyright (C) since 2019 by VTO ltd.";
certificationLevel = 2;
minimumRevision = 40783;

longDescription = "24K40 milling post for Heidenhain TNC 151";

extension = "h";
if (getCodePage() == 932) { // shift-jis is not supported
  setCodePage("ascii");
} else {
  setCodePage("ansi"); // setCodePage("utf-8");
}

capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(5400); // 15 revolutions
allowHelicalMoves = true;
allowedCircularPlanes = undefined; // allow any circular motion



// user-defined properties
properties = {
  preloadTool: false, // preloads next tool on tool change if any
  expandCycles: true, // expands unhandled cycles
  useRigidTapping: true, // rigid tapping
  useParametricFeed: false, // specifies that feed should be output using Q values
  rapidMoveFeedRate: 3000, // specifies that feed should be output using Q values
};

// user-defined property definitions
propertyDefinitions = {
  preloadTool: { title: "Preload tool", description: "Preloads the next tool at a tool change (if any).", group: 1, type: "boolean" },
  expandCycles: { title: "Expand cycles", description: "If enabled, unhandled cycles are expanded.", type: "boolean" },
  useRigidTapping: { title: "Use rigid tapping", description: "Enable to allow rigid tapping.", type: "boolean" },
  useParametricFeed: { title: "Parametric feed", description: "Specifies the feed value that should be output using a Q value.", type: "boolean" },
  rapidMoveFeedRate: { title: "Fast move feed rate", description: "Specifies G00 feed rate, set 0 to exclude F output", type: "number" },
};

var WARNING_WORK_OFFSET = 0;

// collected state
var blockNumber = 0;
var activeMovements; // do not use by default
var workOffsetLabels = {};
var nextLabel = 1;
var retracted = false; // specifies that the tool has been retracted to the safe plane
var decimalSeparator = ',';

var radiusCompensationTable = new Table(
  [" R0", " RL", " RR"],
  { initial: RADIUS_COMPENSATION_OFF },
  "Invalid radius compensation"
);

var xyzFormat = createFormat({ decimals: (unit == MM ? 3 : 4), forceSign: true, separator: decimalSeparator, trim: false });
var abcFormat = createFormat({ decimals: 3, forceSign: true, scale: DEG });
var feedFormat = createFormat({ decimals: (unit == MM ? 0 : 2), scale: (unit == MM ? 1 : 10), separator: decimalSeparator });
var rpmFormat = createFormat({ decimals: 3, separator: decimalSeparator, trim: false });
var secFormat = createFormat({ decimals: 3, separator: decimalSeparator });
var paFormat = createFormat({ decimals: 3, forceSign: true, scale: DEG, separator: decimalSeparator, trim: false });
var angleFormat = createFormat({ decimals: 0, scale: DEG, separator: decimalSeparator, trim: false });
var pitchFormat = createFormat({ decimals: (unit == MM ? 3 : 4), forceSign: true });
var mFormat = createFormat({ prefix: "M", decimals: 0 });

// presentation formats
var spatialFormat = createFormat({ decimals: (unit == MM ? 3 : 4) });
var taperFormat = angleFormat; // share format

var xOutput = createVariable({ prefix: " X" }, xyzFormat);
var yOutput = createVariable({ prefix: " Y" }, xyzFormat);
var zOutput = createVariable({ onchange: function () { retracted = false; }, prefix: " Z" }, xyzFormat);
var feedOutput = createVariable({ prefix: " F" }, feedFormat);


/** Force output of X, Y, and Z. */
function forceXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

/**
  Writes the specified block.
*/
function writeBlock(block) {
  if (!formatWords(block)) {
    return;
  }
  writeln(blockNumber + SP + block);
  ++blockNumber;
}

/**
  Writes the specified block as optional.
*/
function writeOptionalBlock(block) {
  writeln("/" + blockNumber + SP + block);
  ++blockNumber;
}

/** Writes the specified text through the data interface. */
function printData(text) {
  if (isTextSupported(text)) {
    writeln("FN15: PRINT " + text);
  }
}

function onOpen() {
  // NOTE: setup your machine here
  // machineConfiguration = new MachineConfiguration();
  // setMachineConfiguration(machineConfiguration);
  // optimizeMachineAngles2(0); // using M128 mode

  // NOTE: setup your home positions here
  // machineConfiguration.setRetractPlane(-20.415); // home position Z
  // machineConfiguration.setHomePositionX(-200); // home position X
  // machineConfiguration.setHomePositionY(-5); // home position Y

  if (!+programName) {
    error(localize("Program name should be a number"));
  }

  writeBlock(
    "BEGIN PGM" + (programName ? (SP + programName) : "") + ((unit == MM) ? " MM" : " INCH")
  );

  // var tools = getToolTable();
  // if (tools.getNumberOfTools() > 0) {
  //   for (var i = 0; i < tools.getNumberOfTools(); ++i) {
  //     var tool = tools.getTool(i);
  //     writeBlock("TOOL DEF " + tool.number + " L0 R" + xyzFormat.format(tool.diameter / 2.0));
  //   }
  // }
}

function onComment(message) {
  // nothing
}

function invalidateXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

function forceFeed() {
  currentFeedId = undefined;
  feedOutput.reset();
}

/**
  Invalidates the current position and feedrate. Invoke this function to
  force X, Y, Z, A, B, C, and F in the following block.
*/
function invalidate() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
  forceFeed();
}

function getSpindleAxisLetter(axis) {
  if (isSameDirection(axis, new Vector(1, 0, 0))) {
    return "X";
  } else if (isSameDirection(axis, new Vector(0, 1, 0))) {
    return "Y";
  } else if (isSameDirection(axis, new Vector(0, 0, 1))) {
    return "Z";
  } else {
    error(localize("Unsuported spindle axis."));
    return 0;
  }
}

var currentTolerance = undefined;

function setTolerance(tolerance) {
  if (tolerance == currentTolerance) {
    return;
  }
  currentTolerance = tolerance;
}

function FeedContext(id, description, feed) {
  this.id = id;
  this.description = description;
  this.feed = feed;
}

/** Maps the specified feed value to Q feed or formatted feed. */
function getFeed(f) {
  if (activeMovements) {
    var feedContext = activeMovements[movement];
    if (feedContext != undefined) {
      if (!feedFormat.areDifferent(feedContext.feed, f)) {
        if (feedContext.id == currentFeedId) {
          return ""; // nothing has changed
        }
        forceFeed();
        currentFeedId = feedContext.id;
        return " FQ" + (50 + feedContext.id);
      }
    }
    currentFeedId = undefined; // force Q feed next time
  }
  return feedOutput.format(f); // use feed value
}

function getRapidFeed(isLeadSpace, isEndSpace) {
  var rate = properties.rapidMoveFeedRate;

  if (rate < 0) {
    error("Rapid feed rate parameter should be positive or 0");
  }

  var fmt = "F";

  if (isLeadSpace) {
    fmt = " F";
  }

  var result = rate === 0 ? "" : fmt + rate;

  if (isEndSpace) {
    result += " ";
  }

  return result;
}

function initializeActiveFeeds() {
  activeMovements = new Array();
  var movements = currentSection.getMovements();

  var id = 0;
  var activeFeeds = new Array();
  if (hasParameter("operation:tool_feedCutting")) {
    if (movements & ((1 << MOVEMENT_CUTTING) | (1 << MOVEMENT_LINK_TRANSITION) | (1 << MOVEMENT_EXTENDED))) {
      var feedContext = new FeedContext(id, localize("Cutting"), getParameter("operation:tool_feedCutting"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_CUTTING] = feedContext;
      activeMovements[MOVEMENT_LINK_TRANSITION] = feedContext;
      activeMovements[MOVEMENT_EXTENDED] = feedContext;
    }
    ++id;
    if (movements & (1 << MOVEMENT_PREDRILL)) {
      feedContext = new FeedContext(id, localize("Predrilling"), getParameter("operation:tool_feedCutting"));
      activeMovements[MOVEMENT_PREDRILL] = feedContext;
      activeFeeds.push(feedContext);
    }
    ++id;
  }

  if (hasParameter("operation:finishFeedrate")) {
    if (movements & (1 << MOVEMENT_FINISH_CUTTING)) {
      var feedContext = new FeedContext(id, localize("Finish"), getParameter("operation:finishFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_FINISH_CUTTING] = feedContext;
    }
    ++id;
  } else if (hasParameter("operation:tool_feedCutting")) {
    if (movements & (1 << MOVEMENT_FINISH_CUTTING)) {
      var feedContext = new FeedContext(id, localize("Finish"), getParameter("operation:tool_feedCutting"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_FINISH_CUTTING] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:tool_feedEntry")) {
    if (movements & (1 << MOVEMENT_LEAD_IN)) {
      var feedContext = new FeedContext(id, localize("Entry"), getParameter("operation:tool_feedEntry"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LEAD_IN] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:tool_feedExit")) {
    if (movements & (1 << MOVEMENT_LEAD_OUT)) {
      var feedContext = new FeedContext(id, localize("Exit"), getParameter("operation:tool_feedExit"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LEAD_OUT] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:noEngagementFeedrate")) {
    if (movements & (1 << MOVEMENT_LINK_DIRECT)) {
      var feedContext = new FeedContext(id, localize("Direct"), getParameter("operation:noEngagementFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LINK_DIRECT] = feedContext;
    }
    ++id;
  } else if (hasParameter("operation:tool_feedCutting") &&
    hasParameter("operation:tool_feedEntry") &&
    hasParameter("operation:tool_feedExit")) {
    if (movements & (1 << MOVEMENT_LINK_DIRECT)) {
      var feedContext = new FeedContext(id, localize("Direct"), Math.max(getParameter("operation:tool_feedCutting"), getParameter("operation:tool_feedEntry"), getParameter("operation:tool_feedExit")));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_LINK_DIRECT] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:reducedFeedrate")) {
    if (movements & (1 << MOVEMENT_REDUCED)) {
      var feedContext = new FeedContext(id, localize("Reduced"), getParameter("operation:reducedFeedrate"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_REDUCED] = feedContext;
    }
    ++id;
  }

  if (hasParameter("operation:tool_feedRamp")) {
    if (movements & ((1 << MOVEMENT_RAMP) | (1 << MOVEMENT_RAMP_HELIX) | (1 << MOVEMENT_RAMP_PROFILE) | (1 << MOVEMENT_RAMP_ZIG_ZAG))) {
      var feedContext = new FeedContext(id, localize("Ramping"), getParameter("operation:tool_feedRamp"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_RAMP] = feedContext;
      activeMovements[MOVEMENT_RAMP_HELIX] = feedContext;
      activeMovements[MOVEMENT_RAMP_PROFILE] = feedContext;
      activeMovements[MOVEMENT_RAMP_ZIG_ZAG] = feedContext;
    }
    ++id;
  }
  if (hasParameter("operation:tool_feedPlunge")) {
    if (movements & (1 << MOVEMENT_PLUNGE)) {
      var feedContext = new FeedContext(id, localize("Plunge"), getParameter("operation:tool_feedPlunge"));
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_PLUNGE] = feedContext;
    }
    ++id;
  }
  if (true) { // high feed
    if (movements & (1 << MOVEMENT_HIGH_FEED)) {
      var feedContext = new FeedContext(id, localize("High Feed"), this.highFeedrate);
      activeFeeds.push(feedContext);
      activeMovements[MOVEMENT_HIGH_FEED] = feedContext;
    }
    ++id;
  }

  for (var i = 0; i < activeFeeds.length; ++i) {
    var feedContext = activeFeeds[i];
    writeBlock("FN0: Q" + (50 + feedContext.id) + "=" + feedFormat.format(feedContext.feed));
  }
}

function onSection() {
  var insertToolCall = isFirstSection() ||
    (currentSection.getForceToolChange && currentSection.getForceToolChange()) ||
    (tool.number != getPreviousSection().getTool().number) ||
    (tool.clockwise != getPreviousSection().getTool().clockwise);

  retracted = false; // specifies that the tool has been retracted to the safe plane
  // var newWorkOffset = isFirstSection() ||
  //   (getPreviousSection().workOffset != currentSection.workOffset); // work offset changes
  // var newWorkPlane = isFirstSection() ||
  //   !isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), currentSection.getGlobalInitialToolAxis()) ||
  //   (currentSection.isOptimizedForMachine() && getPreviousSection().isOptimizedForMachine() &&
  //     Vector.diff(getPreviousSection().getFinalToolAxisABC(), currentSection.getInitialToolAxisABC()).length > 1e-4) ||
  //   (!machineConfiguration.isMultiAxisConfiguration() && currentSection.isMultiAxis()) ||
  //   (!getPreviousSection().isMultiAxis() && currentSection.isMultiAxis()); // force newWorkPlane between indexing and simultaneous operations

  writeBlock("TOOL DEF " + tool.number + " L0 R" + xyzFormat.format(tool.diameter / 2.0));
  writeRetract(Z);

  // if (newWorkOffset || newWorkPlane) {
  //   // retract to safe plane
  //   writeRetract(Z);
  // }

  if (insertToolCall) {
    onCommand(COMMAND_STOP_SPINDLE);

    if (!isFirstSection()) {
      onCommand(COMMAND_BREAK_CONTROL);
    }

    // if (false) {
    //   var zRange = currentSection.getGlobalZRange();
    //   var numberOfSections = getNumberOfSections();
    //   for (var i = getCurrentSectionId() + 1; i < numberOfSections; ++i) {
    //     var section = getSection(i);
    //     var _tool = section.getTool();
    //     if (_tool.number != tool.number) {
    //       break;
    //     }
    //     zRange.expandToRange(section.getGlobalZRange());
    //   }
    // }


    writeBlock(
      "TOOL CALL " + tool.number + SP + getSpindleAxisLetter(machineConfiguration.getSpindleAxis()) + " S " + rpmFormat.format(spindleSpeed)
    );

    onCommand(COMMAND_TOOL_MEASURE);

    if (properties.preloadTool) {
      var nextTool = getNextTool(tool.number);
      if (nextTool) {
        writeBlock("TOOL DEF " + nextTool.number);
      } else {
        // preload first tool
        var section = getSection(0);
        var firstToolNumber = section.getTool().number;
        if (tool.number != firstToolNumber) {
          writeBlock("TOOL DEF " + firstToolNumber);
        }
      }
    }
  } else {
    if (rpmFormat.areDifferent(spindleSpeed, getPreviousSection().getInitialSpindleSpeed ? getPreviousSection().getInitialSpindleSpeed() : getPreviousSection().getTool().spindleRPM)) {
      onSpindleSpeed(spindleSpeed);
    }
  }

  onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);

  // wcs
  if (currentSection.workOffset > 0) {
    if (currentSection.workOffset > 9999) {
      error(localize("Work offset out of range."));
      return;
    }
    // datum shift after tool call
    writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
    writeBlock("CYCL DEF 7.1 #" + currentSection.workOffset);
  } else {
    warningOnce(localize("Work offset has not been specified."), WARNING_WORK_OFFSET);
  }

  {
    radiusCompensationTable.lookup(RADIUS_COMPENSATION_OFF);
    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);
  }

  invalidate();

  var initialPosition = getFramePosition(currentSection.getInitialPosition());

  if (!retracted && !insertToolCall) {
    if (getCurrentPosition().z < initialPosition.z) {
      writeBlock("L" + zOutput.format(initialPosition.z) + getRapidFeed(true, false));
    }
  }

  if (!machineConfiguration.isHeadConfiguration()) {
    writeBlock("L" + xOutput.format(initialPosition.x) + yOutput.format(initialPosition.y) + " R0" + getRapidFeed(true, false));
    z = zOutput.format(initialPosition.z);
    if (z) {
      writeBlock("L" + z + " R0" + getRapidFeed(true, false));
    }
  } else {
    writeBlock("L" + xOutput.format(initialPosition.x) + yOutput.format(initialPosition.y) + zOutput.format(initialPosition.z) + " R0" + getRapidFeed(true, false));
  }

  if (hasParameter("operation-strategy") && (getParameter("operation-strategy") == "drill")) {
    setTolerance(0);
  } else if (hasParameter("operation:tolerance")) {
    setTolerance(Math.max(getParameter("operation:tolerance"), 0));
  } else {
    setTolerance(0);
  }

  if (properties.useParametricFeed &&
    hasParameter("operation-strategy") &&
    (getParameter("operation-strategy") != "drill") && // legacy
    !(currentSection.hasAnyCycle && currentSection.hasAnyCycle())) {
    if (!insertToolCall &&
      activeMovements &&
      (getCurrentSectionId() > 0) &&
      ((getPreviousSection().getPatternId() == currentSection.getPatternId()) && (currentSection.getPatternId() != 0))) {
      // use the current feeds
    } else {
      initializeActiveFeeds();
    }
  } else {
    activeMovements = undefined;
  }
  retracted = false;
}

function onDwell(seconds) {
  validate(seconds >= 0);
  writeBlock("CYCL DEF 9.0 " + localize("DWELL TIME"));
  writeBlock("CYCL DEF 9.1 DWELL " + secFormat.format(seconds));
}

function onParameter(name, value) {
  // nothing
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(
    "TOOL CALL " + getSpindleAxisLetter(machineConfiguration.getSpindleAxis()) + " S " + rpmFormat.format(spindleSpeed)
  );
}

function onDrilling(cycle) {
  writeBlock("CYCL DEF 1.0 PECKING");
  writeBlock("CYCL DEF 1.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
  writeBlock("CYCL DEF 1.2 DEPTH " + xyzFormat.format(-cycle.depth));
  writeBlock("CYCL DEF 1.3 PECKG " + xyzFormat.format(cycle.depth));
  writeBlock("CYCL DEF 1.4 DWELL " + secFormat.format(cycle.dwell));
  writeBlock("CYCL DEF 1.5 F" + feedFormat.format(cycle.feedrate));
}

function onCounterBoring(cycle) {
  writeBlock("CYCL DEF 1.0 PECKING");
  writeBlock("CYCL DEF 1.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
  writeBlock("CYCL DEF 1.2 DEPTH " + xyzFormat.format(-cycle.depth));
  writeBlock("CYCL DEF 1.3 PECKG " + xyzFormat.format(cycle.depth));
  writeBlock("CYCL DEF 1.4 DWELL " + secFormat.format(cycle.dwell));
  writeBlock("CYCL DEF 1.5 F" + feedFormat.format(cycle.feedrate));
}

function onChipBreaking(cycle) {
  writeBlock("CYCL DEF 1.0 PECKING");
  writeBlock("CYCL DEF 1.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
  writeBlock("CYCL DEF 1.2 DEPTH " + xyzFormat.format(-cycle.depth));
  writeBlock("CYCL DEF 1.3 PECKG " + xyzFormat.format(cycle.incrementalDepth));
  writeBlock("CYCL DEF 1.4 DWELL " + secFormat.format(cycle.dwell));
  writeBlock("CYCL DEF 1.5 F" + feedFormat.format(cycle.feedrate));
}

function onDeepDrilling(cycle) {
  writeBlock("CYCL DEF 1.0 PECKING");
  writeBlock("CYCL DEF 1.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
  writeBlock("CYCL DEF 1.2 DEPTH " + xyzFormat.format(-cycle.depth));
  writeBlock("CYCL DEF 1.3 PECKG " + xyzFormat.format(cycle.incrementalDepth));
  writeBlock("CYCL DEF 1.4 DWELL " + secFormat.format(cycle.dwell));
  writeBlock("CYCL DEF 1.5 F" + feedFormat.format(cycle.feedrate));
}

function onLeftTapping(cycle) {
  if (properties.useRigidTapping) {
    writeBlock("CYCL DEF 17.0 TAPPING");
    writeBlock("CYCL DEF 17.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
    writeBlock("CYCL DEF 17.2 DEPTH " + xyzFormat.format(-cycle.depth));
    writeBlock("CYCL DEF 17.3 PITCH " + pitchFormat.format(-tool.threadPitch));
  } else {
    expandCurrentCycle = properties.expandCycles;
    if (!expandCurrentCycle) {
      cycleNotSupported();
    }
  }
}

function onRightTapping(cycle) {
  if (properties.useRigidTapping) {
    writeBlock("CYCL DEF 17.0 TAPPING");
    writeBlock("CYCL DEF 17.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
    writeBlock("CYCL DEF 17.2 DEPTH " + xyzFormat.format(-cycle.depth));
    writeBlock("CYCL DEF 17.3 PITCH " + pitchFormat.format(tool.threadPitch));
  } else {
    writeBlock("CYCL DEF 2.0 TAPPING");
    writeBlock("CYCL DEF 2.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
    writeBlock("CYCL DEF 2.2 DEPTH " + xyzFormat.format(-cycle.depth));
    writeBlock("CYCL DEF 2.3 DWELL 0");
    writeBlock("CYCL DEF 2.4 F" + feedFormat.format(tool.getTappingFeedrate()));
  }
}

function onCircularPocketMilling(cycle) {
  if (tool.taperAngle > 0) {
    error(localize("Circular pocket milling is not supported for taper tools."));
    return;
  }
  writeBlock("CYCL DEF 5.0 CIRCULAR POCKET");
  writeBlock("CYCL DEF 5.1 SET UP " + xyzFormat.format(cycle.clearance - cycle.stock));
  writeBlock("CYCL DEF 5.2 DEPTH " + xyzFormat.format(-cycle.depth));
  writeBlock("CYCL DEF 5.3 PECKG " + xyzFormat.format(cycle.incrementalDepth) + " F" + feedFormat.format(cycle.feedrate / 3));
  writeBlock("CYCL DEF 5.4 RADIUS " + xyzFormat.format(cycle.diameter / 2));
  writeBlock("CYCL DEF 5.5 F" + feedFormat.format(cycle.feedrate) + " DR+");
}

/** Returns the best discrete disengagement direction for the specified direction. */
function getDisengagementDirection(direction) {
  switch (getQuadrant(direction + 45 * Math.PI / 180)) {
    case 0:
      return 3;
    case 1:
      return 4;
    case 2:
      return 1;
    case 3:
      return 2;
  }
  error(localize("Invalid disengagement direction."));
  return 3;
}

var expandCurrentCycle = false;

function onCycle() {
  if (!isSameDirection(getRotation().forward, new Vector(0, 0, 1))) {
    expandCurrentCycle = properties.expandCycles;
    if (!expandCurrentCycle) {
      cycleNotSupported();
    }
    return;
  }
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a cycle."));
    return;
  }

  expandCurrentCycle = false;

  if (cycle.clearance != undefined) {
    if (getCurrentPosition().z < cycle.clearance) {
      writeBlock("L" + zOutput.format(cycle.clearance) + radiusCompensationTable.lookup(radiusCompensation) + getRapidFeed(true, false));
      setCurrentPositionZ(cycle.clearance);
    }
  }

  switch (cycleType) {
    case "drilling": // G81 style
      onDrilling(cycle);
      break;
    case "counter-boring":
      onCounterBoring(cycle);
      break;
    case "chip-breaking":
      onChipBreaking(cycle);
      break;
    case "deep-drilling":
      onDeepDrilling(cycle);
      break;
    case "tapping":
      if (tool.type == TOOL_TAP_LEFT_HAND) {
        onLeftTapping(cycle);
      } else {
        onRightTapping(cycle);
      }
      break;
    case "left-tapping":
      onLeftTapping(cycle);
      break;
    case "right-tapping":
      onRightTapping(cycle);
      break;
    case "circular-pocket-milling":
      onCircularPocketMilling(cycle);
      break;
    default:
      expandCurrentCycle = properties.expandCycles;
      if (!expandCurrentCycle) {
        cycleNotSupported();
      }
  }
}

function onCyclePoint(x, y, z) {
  if (!expandCurrentCycle) {
    var xy = xOutput.format(x) + yOutput.format(y);
    // execute current cycle after this positioning block
    if (spatialFormat.areDifferent(getCurrentPosition().z, cycle.clearance)) { // old heidenhain cycles do not support "2nd set-up clearance"
      if (xy) {
        writeBlock("L" + xy + getRapidFeed(true, false));
      }
      writeBlock("L" + zOutput.format(cycle.clearance) + radiusCompensationTable.lookup(radiusCompensation) + getRapidFeed(true, true) + mFormat.format(99));
    } else {
      writeBlock("L" + xy + getRapidFeed(true, true) + mFormat.format(99));
    }
  } else {
    expandCyclePoint(x, y, z);
  }
}

function onCycleEnd() {
  zOutput.reset();
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
  pendingRadiusCompensation = radiusCompensation;
}

function onRapid(x, y, z) {
  var xyz = xOutput.format(x) + yOutput.format(y) + zOutput.format(z);
  if (xyz) {
    pendingRadiusCompensation = -1;
    writeBlock("L" + xyz + radiusCompensationTable.lookup(radiusCompensation) + getRapidFeed(true, false));
  }
  forceFeed();
}

function onLinear(x, y, z, feed) {
  var xyz = xOutput.format(x) + yOutput.format(y) + zOutput.format(z);
  var f = getFeed(feed);
  if (xyz) {
    pendingRadiusCompensation = -1;
    writeBlock("L" + xyz + radiusCompensationTable.lookup(radiusCompensation) + f);
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      forceFeed(); // force feed on next line
    } else {
      pendingRadiusCompensation = -1;
      writeBlock("L" + radiusCompensationTable.lookup(radiusCompensation) + f);
    }
  }
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
    return;
  }

  switch (getCircularPlane()) {
    case PLANE_XY:
      writeBlock("CC X" + xyzFormat.format(cx) + " Y" + xyzFormat.format(cy));
      break;
    case PLANE_ZX:
      if (isHelical()) {
        var t = tolerance;
        if ((t == 0) && hasParameter("operation:tolerance")) {
          t = getParameter("operation:tolerance");
        }
        linearize(t);
        return;
      }
      writeBlock("CC X" + xyzFormat.format(cx) + " Z" + xyzFormat.format(cz));
      break;
    case PLANE_YZ:
      if (isHelical()) {
        var t = tolerance;
        if ((t == 0) && hasParameter("operation:tolerance")) {
          t = getParameter("operation:tolerance");
        }
        linearize(t);
        return;
      }
      writeBlock("CC Y" + xyzFormat.format(cy) + " Z" + xyzFormat.format(cz));
      break;
    default:
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
      return;
  }

  if (!isHelical() && (Math.abs(getCircularSweep()) <= 2 * Math.PI * 0.9)) {
    switch (getCircularPlane()) {
      case PLANE_XY:
        writeBlock(
          "C" + xOutput.format(x) + yOutput.format(y) +
          (clockwise ? " DR-" : " DR+") +
          radiusCompensationTable.lookup(radiusCompensation) +
          getFeed(feed)
        );
        break;
      case PLANE_ZX:
        writeBlock(
          "C" + xOutput.format(x) + zOutput.format(z) +
          (clockwise ? " DR-" : " DR+") +
          radiusCompensationTable.lookup(radiusCompensation) +
          getFeed(feed)
        );
        break;
      case PLANE_YZ:
        writeBlock(
          "C" + yOutput.format(y) + zOutput.format(z) +
          (clockwise ? " DR-" : " DR+") +
          radiusCompensationTable.lookup(radiusCompensation) +
          getFeed(feed)
        );
        break;
      default:
        var t = tolerance;
        if ((t == 0) && hasParameter("operation:tolerance")) {
          t = getParameter("operation:tolerance");
        }
        linearize(t);
    }
    return;
  }

  if (isHelical()) {
    if (getCircularPlane() == PLANE_XY) {
      // IPA must have same sign as DR
      var sweep = (clockwise ? -1 : 1) * Math.abs(getCircularSweep());
      var block = "CP IPA" + paFormat.format(sweep) + zOutput.format(z);
      block += clockwise ? " DR-" : " DR+";
      block += /*radiusCompensationTable.lookup(radiusCompensation) +*/ getFeed(feed);
      writeBlock(block);
      xOutput.reset();
      yOutput.reset();
    } else {
      var t = tolerance;
      if ((t == 0) && hasParameter("operation:tolerance")) {
        t = getParameter("operation:tolerance");
      }
      linearize(t);
    }
  } else {
    // IPA must have same sign as DR
    var sweep = (clockwise ? -1 : 1) * Math.abs(getCircularSweep());
    var block = "CP IPA" + paFormat.format(sweep);
    block += clockwise ? " DR-" : " DR+";
    block += /*radiusCompensationTable.lookup(radiusCompensation) +*/ getFeed(feed);
    writeBlock(block);

    switch (getCircularPlane()) {
      case PLANE_XY:
        xOutput.reset();
        yOutput.reset();
        break;
      case PLANE_ZX:
        xOutput.reset();
        zOutput.reset();
        break;
      case PLANE_YZ:
        yOutput.reset();
        zOutput.reset();
        break;
      default:
        invalidateXYZ();
    }
  }
}

var mapCommand = {
  COMMAND_STOP: 0,
  COMMAND_END: 30,
  COMMAND_SPINDLE_CLOCKWISE: 3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE: 4,
  // COMMAND_START_SPINDLE
  COMMAND_STOP_SPINDLE: 5
};

function onCommand(command) {
  switch (command) {
    case COMMAND_START_SPINDLE:
      onCommand(tool.clockwise ? COMMAND_SPINDLE_CLOCKWISE : COMMAND_SPINDLE_COUNTERCLOCKWISE);
      return;
    case COMMAND_LOCK_MULTI_AXIS:
      return;
    case COMMAND_UNLOCK_MULTI_AXIS:
      return;
    case COMMAND_BREAK_CONTROL:
      return;
    case COMMAND_TOOL_MEASURE:
      return;
    case COMMAND_STOP_SPINDLE:
      var stringId = getCommandStringId(command);
      var mcode = mapCommand[stringId];
      if (mcode) {
        writeBlock("STOP" + SP + mFormat.format(mcode));
      } else {
        onUnsupportedCommand(command);
      }
      return;
      case COMMAND_SPINDLE_CLOCKWISE:
      case COMMAND_SPINDLE_COUNTERCLOCKWISE:
        var stringId = getCommandStringId(command);
        var mcode = mapCommand[stringId];
        if (mcode != undefined) {
          writeBlock("L R F" + SP + mFormat.format(mcode));
        } else {
          onUnsupportedCommand(command);
        }
      return;
  }

  var stringId = getCommandStringId(command);
  var mcode = mapCommand[stringId];
  if (mcode != undefined) {
    writeBlock(mFormat.format(mcode));
  } else {
    onUnsupportedCommand(command);
  }
}

function onSectionEnd() {
  invalidate();
}


properties.homeXYAtEnd = false;
if (propertyDefinitions === undefined) {
  propertyDefinitions = {};
}
propertyDefinitions.homeXYAtEnd = { title: "Home XY at end", description: "Specifies that the machine moves to the home position in XY at the end of the program.", type: "boolean" };

/** Output block to do safe retract and/or move to home position. */
function writeRetract() {
  if (arguments.length == 0) {
    error(localize("No axis specified for writeRetract()."));
    return;
  }
  var words = []; // store all retracted axes in an array
  for (var i = 0; i < arguments.length; ++i) {
    let instances = 0; // checks for duplicate retract calls
    for (var j = 0; j < arguments.length; ++j) {
      if (arguments[i] == arguments[j]) {
        ++instances;
      }
    }
    if (instances > 1) { // error if there are multiple retract calls for the same axis
      error(localize("Cannot retract the same axis twice in one line"));
      return;
    }
    switch (arguments[i]) {
      case X:
        words.push("X" + xyzFormat.format(machineConfiguration.hasHomePositionX() ? machineConfiguration.getHomePositionX() : 0));
        break;
      case Y:
        words.push("Y" + xyzFormat.format(machineConfiguration.hasHomePositionY() ? machineConfiguration.getHomePositionY() : 0));
        break;
      case Z:
        words.push("Z" + xyzFormat.format(machineConfiguration.getRetractPlane()));
        retracted = true; // specifies that the tool has been retracted to the safe plane
        zOutput.reset();
        break;
      default:
        error(localize("Bad axis specified for writeRetract()."));
        return;
    }
  }
  if (words.length > 0) {
    writeBlock("L " + words.join(" ") + " R0" + getRapidFeed(true, true) + mFormat.format(91));
  }
}

function onClose() {
  setTolerance(0);
  if (getNumberOfSections() > 0) {
    onCommand(COMMAND_BREAK_CONTROL);
  }

  onCommand(COMMAND_STOP_SPINDLE);

  //writeBlock("CYCL DEF 7.0 " + localize("DATUM SHIFT"));
  //writeBlock("CYCL DEF 7.1 #" + 0);

  writeRetract(Z);

  if (properties.homeXYAtEnd) {
    writeRetract(X, Y);
  }

  writeBlock(mFormat.format(2)); // stop program, spindle stop

  writeBlock(
    "END PGM" + (programName ? (SP + programName) : "") + ((unit == MM) ? " MM" : " INCH")
  );
}
