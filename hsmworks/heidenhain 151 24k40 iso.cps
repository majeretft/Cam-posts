/**
  Heidenhain ISO post processor configuration.
*/

description = "24K40 Heidenhain TNC 151 ISO";
vendor = "VTO ltd.";
vendorUrl = "hozpm@mail.ru";
legal = "Copyright (C) since 2019 by VTO ltd.";
certificationLevel = 2;
minimumRevision = 40783;

longDescription = "24K40 milling post for Heidenhain TNC 151 ISO";

extension = "i";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.002, MM);

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined; // allow any circular motion



// user-defined properties
properties = {
  preloadTool: false, // preloads next tool on tool change if any
  showSequenceNumbers: true, // show sequence numbers
  sequenceNumberStart: 1, // first sequence number
  sequenceNumberIncrement: 1, // increment for sequence numbers
  optionalStop: true, // optional stop
  useRadius: false, // specifies that arcs should be output using the radius (R word) instead of the I, J, and K words.
  useM92: false // use M92 instead of M91
};

// user-defined property definitions
propertyDefinitions = {
  preloadTool: { title: "Preload tool", description: "Preloads the next tool at a tool change (if any).", type: "boolean" },
  showSequenceNumbers: { title: "Use sequence numbers", description: "Use sequence numbers for each block of outputted code.", group: 1, type: "boolean" },
  sequenceNumberStart: { title: "Start sequence number", description: "The number at which to start the sequence numbers.", group: 1, type: "integer" },
  sequenceNumberIncrement: { title: "Sequence number increment", description: "The amount by which the sequence number is incremented by in each block.", group: 1, type: "integer" },
  optionalStop: { title: "Optional stop", description: "Outputs optional stop code during when necessary in the code.", type: "boolean" },
  useRadius: { title: "Radius arcs", description: "If yes is selected, arcs are outputted using radius values rather than IJK.", type: "boolean" },
  useM92: { title: "Use M92", description: "If enabled, M91 is used instead of M91.", type: "boolean" }
};

var gFormat = createFormat({ prefix: "G", width: 2, zeropad: true, decimals: 1 });
var mFormat = createFormat({ prefix: "M", width: 2, zeropad: true, decimals: 1 });
var hFormat = createFormat({ prefix: "H", width: 2, zeropad: true, decimals: 1 });
var dFormat = createFormat({ prefix: "D", width: 2, zeropad: true, decimals: 1 });

var xyzFormat = createFormat({ decimals: (unit == MM ? 3 : 4), forceDecimal: true, forceSign: true });
var rFormat = xyzFormat; // radius
var abcFormat = createFormat({ decimals: 3, forceDecimal: true, scale: DEG });
var feedFormat = createFormat({ decimals: (unit == MM ? 0 : 1), forceDecimal: true });
var toolFormat = createFormat({ decimals: 0 });
var rpmFormat = createFormat({ decimals: 0 });
var secFormat = createFormat({ decimals: 3 }); // seconds - range 0.001-99999.999
var taperFormat = createFormat({ decimals: 1, scale: DEG });

var xOutput = createVariable({ prefix: "X" }, xyzFormat);
var yOutput = createVariable({ prefix: "Y" }, xyzFormat);
var zOutput = createVariable({ onchange: function () { retracted = false; }, prefix: "Z" }, xyzFormat);
var aOutput = createVariable({ prefix: "A" }, abcFormat);
var bOutput = createVariable({ prefix: "B" }, abcFormat);
var cOutput = createVariable({ prefix: "C" }, abcFormat);
var feedOutput = createVariable({ prefix: "F" }, feedFormat);
var sOutput = createVariable({ prefix: "S", force: true }, rpmFormat);

// circular output
var iOutput = createVariable({ prefix: "I", force: true }, xyzFormat);
var jOutput = createVariable({ prefix: "J", force: true }, xyzFormat);
var kOutput = createVariable({ prefix: "K", force: true }, xyzFormat);

var gMotionModal = createModal({}, gFormat); // modal group 1 // G0-G3, ...
var gPlaneModal = createModal({ onchange: function () { gMotionModal.reset(); } }, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); // modal group 5 // G93-94
var gUnitModal = createModal({ force: true }, gFormat); // modal group 6 // G70-71

var WARNING_WORK_OFFSET = 0;
var retracted = false; // specifies that the tool has been retracted to the safe plane

// collected state
var sequenceNumber;
var currentWorkOffset;

/**
  Writes the specified block.
*/
function writeBlock() {
  var text = formatWords(arguments);
  if (!text) {
    return;
  }
  if (properties.showSequenceNumbers) {
    writeWords2("N" + sequenceNumber, arguments);
    sequenceNumber += properties.sequenceNumberIncrement;
  } else {
    writeWords(arguments);
  }
}

function onOpen() {
  if (properties.useRadius) {
    maximumCircularSweep = toRad(90); // avoid potential center calculation errors for CNC
  }

  // if (false) { // note: setup your machine here
  //   var aAxis = createAxis({coordinate:0, table:false, axis:[1, 0, 0], range:[-360, 360], preference:1});
  //   var cAxis = createAxis({coordinate:2, table:false, axis:[0, 0, 1], range:[-360, 360], preference:1});
  //   machineConfiguration = new MachineConfiguration(aAxis, cAxis);

  //   setMachineConfiguration(machineConfiguration);
  //   optimizeMachineAngles2(0); // TCP mode
  // }

  /*
    // NOTE: setup your home positions here
    machineConfiguration.setRetractPlane(-20.415); // home position Z
    machineConfiguration.setHomePositionX(-200); // home position X
    machineConfiguration.setHomePositionY(-5); // home position Y
  */

  if (!machineConfiguration.isMachineCoordinate(0)) {
    aOutput.disable();
  }
  if (!machineConfiguration.isMachineCoordinate(1)) {
    bOutput.disable();
  }
  if (!machineConfiguration.isMachineCoordinate(2)) {
    cOutput.disable();
  }

  sequenceNumber = properties.sequenceNumberStart;

  writeBlock(
    "%" + programName, gUnitModal.format((unit == MM) ? 71 : 70)
  );

  { // stock - workpiece
    var workpiece = getWorkpiece();
    var delta = Vector.diff(workpiece.upper, workpiece.lower);
    if (delta.isNonZero()) {
      writeBlock(gFormat.format(30), gPlaneModal.format(17), "X" + xyzFormat.format(workpiece.lower.x) + " Y" + xyzFormat.format(workpiece.lower.y) + " Z" + xyzFormat.format(workpiece.lower.z));
      writeBlock(gFormat.format(31), gAbsIncModal.format(90), "X" + xyzFormat.format(workpiece.upper.x) + " Y" + xyzFormat.format(workpiece.upper.y) + " Z" + xyzFormat.format(workpiece.upper.z));
    }
  }

  // absolute coordinates and feed per min
  writeBlock(gAbsIncModal.format(90), gFeedModeModal.format(94), gPlaneModal.format(17));
}

function onComment() { }

/** Force output of X, Y, and Z. */
function forceXYZ() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
}

/** Force output of A, B, and C. */
function forceABC() {
  aOutput.reset();
  bOutput.reset();
  cOutput.reset();
}

/** Force output of X, Y, Z, A, B, C, and F on next output. */
function forceAny() {
  forceXYZ();
  forceABC();
  feedOutput.reset();
}

function onParameter(name, value) {
}

var currentWorkPlaneABC = undefined;

function forceWorkPlane() {
  currentWorkPlaneABC = undefined;
}

function setWorkPlane(abc) {
  if (!machineConfiguration.isMultiAxisConfiguration()) {
    return; // ignore
  }

  if (!((currentWorkPlaneABC == undefined) ||
    abcFormat.areDifferent(abc.x, currentWorkPlaneABC.x) ||
    abcFormat.areDifferent(abc.y, currentWorkPlaneABC.y) ||
    abcFormat.areDifferent(abc.z, currentWorkPlaneABC.z))) {
    return; // no change
  }
  if (!retracted) {
    writeRetract(Z);
  }

  onCommand(COMMAND_UNLOCK_MULTI_AXIS);

  // NOTE: add retract here

  writeBlock(
    gMotionModal.format(0),
    conditional(machineConfiguration.isMachineCoordinate(0), "A" + abcFormat.format(abc.x)),
    conditional(machineConfiguration.isMachineCoordinate(1), "B" + abcFormat.format(abc.y)),
    conditional(machineConfiguration.isMachineCoordinate(2), "C" + abcFormat.format(abc.z))
  );

  onCommand(COMMAND_LOCK_MULTI_AXIS);

  currentWorkPlaneABC = abc;
}

var closestABC = false; // choose closest machine angles
var currentMachineABC;

function getWorkPlaneMachineABC(workPlane) {
  var W = workPlane; // map to global frame

  var abc = machineConfiguration.getABC(W);
  if (closestABC) {
    if (currentMachineABC) {
      abc = machineConfiguration.remapToABC(abc, currentMachineABC);
    } else {
      abc = machineConfiguration.getPreferredABC(abc);
    }
  } else {
    abc = machineConfiguration.getPreferredABC(abc);
  }

  try {
    abc = machineConfiguration.remapABC(abc);
    currentMachineABC = abc;
  } catch (e) {
    error(
      localize("Machine angles not supported") + ":"
      + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
      + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
      + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
    );
  }

  var direction = machineConfiguration.getDirection(abc);
  if (!isSameDirection(direction, W.forward)) {
    error(localize("Orientation not supported."));
  }

  if (!machineConfiguration.isABCSupported(abc)) {
    error(
      localize("Work plane is not supported") + ":"
      + conditional(machineConfiguration.isMachineCoordinate(0), " A" + abcFormat.format(abc.x))
      + conditional(machineConfiguration.isMachineCoordinate(1), " B" + abcFormat.format(abc.y))
      + conditional(machineConfiguration.isMachineCoordinate(2), " C" + abcFormat.format(abc.z))
    );
  }

  var tcp = true;
  if (tcp) {
    setRotation(W); // TCP mode
  } else {
    var O = machineConfiguration.getOrientation(abc);
    var R = machineConfiguration.getRemainingOrientation(abc, W);
    setRotation(R);
  }

  return abc;
}

function onSection() {
  var insertToolCall = isFirstSection() ||
    currentSection.getForceToolChange && currentSection.getForceToolChange() ||
    (tool.number != getPreviousSection().getTool().number);

  retracted = false; // specifies that the tool has been retracted to the safe plane
  var newWorkOffset = isFirstSection() ||
    (getPreviousSection().workOffset != currentSection.workOffset); // work offset changes
  var newWorkPlane = isFirstSection() ||
    !isSameDirection(getPreviousSection().getGlobalFinalToolAxis(), currentSection.getGlobalInitialToolAxis()) ||
    (currentSection.isOptimizedForMachine() && getPreviousSection().isOptimizedForMachine() &&
      Vector.diff(getPreviousSection().getFinalToolAxisABC(), currentSection.getInitialToolAxisABC()).length > 1e-4) ||
    (!machineConfiguration.isMultiAxisConfiguration() && currentSection.isMultiAxis()) ||
    (!getPreviousSection().isMultiAxis() && currentSection.isMultiAxis() ||
      getPreviousSection().isMultiAxis() && !currentSection.isMultiAxis()); // force newWorkPlane between indexing and simultaneous operations
  if (insertToolCall || newWorkOffset || newWorkPlane) {
    // retract to safe plane
    writeRetract(Z);
    writeBlock(gAbsIncModal.format(90));
  }

  if (insertToolCall) {
    forceWorkPlane();

    onCommand(COMMAND_COOLANT_OFF);

    if (!isFirstSection() && properties.optionalStop) {
      onCommand(COMMAND_OPTIONAL_STOP);
    }

    if (tool.number > 99) {
      warning(localize("Tool number exceeds maximum value."));
    }

    /*
        writeBlock(
          gFormat.format(99), "T" + tool.number, "L" + xyzFormat.format(tool.bodyLength), "R" + xyzFormat.format(tool.diameter/2)
        );
        */
    gPlaneModal.reset();
    writeBlock(
      "T" + tool.number, gPlaneModal.format(17), sOutput.format(spindleSpeed)
    );
    var showToolZMin = false;
    if (showToolZMin) {
      if (is3D()) {
        var numberOfSections = getNumberOfSections();
        var zRange = currentSection.getGlobalZRange();
        var number = tool.number;
        for (var i = currentSection.getId() + 1; i < numberOfSections; ++i) {
          var section = getSection(i);
          if (section.getTool().number != number) {
            break;
          }
          zRange.expandToRange(section.getGlobalZRange());
        }
      }
    }

    if (properties.preloadTool) {
      var nextTool = getNextTool(tool.number);
      if (nextTool) {
        writeBlock(gFormat.format(51), "T" + toolFormat.format(nextTool.number));
      } else {
        // preload first tool
        var section = getSection(0);
        var firstToolNumber = section.getTool().number;
        if (tool.number != firstToolNumber) {
          writeBlock(gFormat.format(51), "T" + toolFormat.format(firstToolNumber));
        }
      }
    }
  }

  if (insertToolCall ||
    isFirstSection() ||
    (rpmFormat.areDifferent(spindleSpeed, sOutput.getCurrent())) ||
    (tool.clockwise != getPreviousSection().getTool().clockwise)) {
    if (spindleSpeed < 1) {
      error(localize("Spindle speed out of range."));
    }
    if (spindleSpeed > 99999) {
      warning(localize("Spindle speed exceeds maximum value."));
    }
    writeBlock(
      sOutput.format(spindleSpeed), mFormat.format(tool.clockwise ? 3 : 4)
    );
  }

  // wcs
  /*
  if (insertToolCall) { // force work offset when changing tool
    currentWorkOffset = undefined;
  }
  var workOffset = currentSection.workOffset;
  if (workOffset == 0) {
    warningOnce(localize("Work offset has not been specified. Using G54 as WCS."), WARNING_WORK_OFFSET);
    workOffset = 1;
  }
  if (workOffset > 0) {
    if (workOffset > 6) {
      var p = workOffset - 6; // 1->...
      error(localize("Work offset out of range."));
    } else {
      if (workOffset != currentWorkOffset) {
        writeBlock(gFormat.format(53 + workOffset)); // G54->G59
        currentWorkOffset = workOffset;
      }
    }
  }
  */

  forceXYZ();

  if (machineConfiguration.isMultiAxisConfiguration()) { // use 5-axis indexing for multi-axis mode
    // set working plane after datum shift

    var abc = new Vector(0, 0, 0);
    if (currentSection.isMultiAxis()) {
      forceWorkPlane();
      cancelTransformation();
    } else {
      abc = getWorkPlaneMachineABC(currentSection.workPlane);
    }
    setWorkPlane(abc);
  } else { // pure 3D
    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1))) {
      error(localize("Tool orientation is not supported."));
      return;
    }
    setRotation(remaining);
  }

  // set coolant after we have positioned at Z
  setCoolant(tool.coolant);

  forceAny();
  gMotionModal.reset();

  var initialPosition = getFramePosition(currentSection.getInitialPosition());
  if (!retracted && !insertToolCall) {
    if (getCurrentPosition().z < initialPosition.z) {
      writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
    }
  }

  if (insertToolCall) {
    gMotionModal.reset();
    writeBlock(gPlaneModal.format(17));

    if (!machineConfiguration.isHeadConfiguration()) {
      writeBlock(
        gAbsIncModal.format(90),
        gMotionModal.format(0), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y)
      );
      writeBlock(gMotionModal.format(0), zOutput.format(initialPosition.z));
    } else {
      writeBlock(
        gAbsIncModal.format(90),
        gMotionModal.format(0),
        xOutput.format(initialPosition.x),
        yOutput.format(initialPosition.y),
        zOutput.format(initialPosition.z)
      );
    }

    gMotionModal.reset();
  } else {
    writeBlock(
      gAbsIncModal.format(90),
      gMotionModal.format(0),
      xOutput.format(initialPosition.x),
      yOutput.format(initialPosition.y)
    );
  }
  retracted = false;
}

function onDwell(seconds) {
  if (seconds > 99999.999) {
    warning(localize("Dwelling time is out of range."));
  }
  writeBlock(gFeedModeModal.format(94), gFormat.format(4), "F" + secFormat.format(seconds));
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(sOutput.format(spindleSpeed));
}

function onCycle() {
  writeBlock(gPlaneModal.format(17));
}

function getCommonCycle(x, y, z, r) {
  forceXYZ();
  return [xOutput.format(x), yOutput.format(y),
  zOutput.format(z),
  "R" + xyzFormat.format(r)];
}

function onCyclePoint(x, y, z) {
  if (!isSameDirection(getRotation().forward, new Vector(0, 0, 1))) {
    expandCyclePoint(x, y, z);
    return;
  }
  if (isFirstCyclePoint()) {
    repositionToCycleClearance(cycle, x, y, z);

    // return to initial Z which is clearance plane and set absolute mode

    var F = cycle.feedrate;
    var P = !cycle.dwell ? 0 : clamp(0.001, cycle.dwell, 99999.999); // in seconds

    switch (cycleType) {
      case "drilling":
      case "counter-boring":
        writeBlock(
          gAbsIncModal.format(90), gFormat.format(83),
          "P01 " + xyzFormat.format(cycle.stock - cycle.clearance),
          "P02 " + xyzFormat.format(-cycle.depth),
          "P03 " + xyzFormat.format(-cycle.depth),
          "P04 " + secFormat.format(P),
          "P05 " + feedOutput.format(F)
        );
        writeBlock(xOutput.format(x), yOutput.format(y), mFormat.format(99));
        break;
      case "chip-breaking":
        // cycle.accumulatedDepth is ignored
        writeBlock(
          gAbsIncModal.format(90), gFormat.format(83),
          "P01 " + xyzFormat.format(cycle.stock - cycle.clearance),
          "P02 " + xyzFormat.format(-cycle.depth),
          "P03 " + xyzFormat.format(cycle.incrementalDepth),
          "P04 " + secFormat.format(P),
          "P05 " + feedOutput.format(F)
        );
        writeBlock(xOutput.format(x), yOutput.format(y), mFormat.format(99));
        break;
      case "deep-drilling":
        writeBlock(
          gAbsIncModal.format(90), gFormat.format(83),
          "P01 " + xyzFormat.format(cycle.stock - cycle.clearance),
          "P02 " + xyzFormat.format(-cycle.depth),
          "P03 " + xyzFormat.format(cycle.incrementalDepth),
          "P04 " + secFormat.format(P),
          "P05 " + feedOutput.format(F)
        );
        writeBlock(xOutput.format(x), yOutput.format(y), mFormat.format(99));
        break;
      case "tapping":
      case "left-tapping":
      case "right-tapping":
        // cycles calculates feed from spindle speed and pitch
        writeBlock(
          gAbsIncModal.format(90), gFormat.format(85),
          "P01 " + xyzFormat.format(cycle.stock - cycle.clearance),
          "P02 " + xyzFormat.format(-cycle.depth),
          "P03 " + xyzFormat.format(((tool.type == TOOL_TAP_LEFT_HAND) ? -1 : 1) * tool.threadPitch)
        );
        writeBlock(xOutput.format(x), yOutput.format(y), mFormat.format(99));
        break;
      case "tapping-with-chip-breaking":
      case "left-tapping-with-chip-breaking":
      case "right-tapping-with-chip-breaking":
      case "fine-boring":
      case "back-boring":
      case "reaming":
      case "stop-boring":
      case "manual-boring":
      case "boring":
      default:
        expandCyclePoint(x, y, z);
    }
  } else {
    if (cycleExpanded) {
      expandCyclePoint(x, y, z);
    } else {
      writeBlock(xOutput.format(x), yOutput.format(y), mFormat.format(99));
    }
  }
}

function onCycleEnd() {
  if (!cycleExpanded) {
    zOutput.reset();
  }
}

var pendingRadiusCompensation = -1;

function onRadiusCompensation() {
  pendingRadiusCompensation = radiusCompensation;
}

function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      error(localize("Radius compensation mode cannot be changed at rapid traversal."));
    }
    writeBlock(gMotionModal.format(0), x, y, z);
    feedOutput.reset();
  }
}

function onLinear(_x, _y, _z, feed) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = feedOutput.format(feed);
  if (x || y || z) {
    if (pendingRadiusCompensation >= 0) {
      pendingRadiusCompensation = -1;
      writeBlock(gPlaneModal.format(17));
      switch (radiusCompensation) {
        case RADIUS_COMPENSATION_LEFT:
          writeBlock(gMotionModal.format(1), gFormat.format(41), x, y, z, f);
          break;
        case RADIUS_COMPENSATION_RIGHT:
          writeBlock(gMotionModal.format(1), gFormat.format(42), x, y, z, f);
          break;
        default:
          writeBlock(gMotionModal.format(1), gFormat.format(40), x, y, z, f);
      }
    } else {
      writeBlock(gMotionModal.format(1), x, y, z, f);
    }
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      feedOutput.reset(); // force feed on next line
    } else {
      writeBlock(gMotionModal.format(1), f);
    }
  }
}

function onRapid5D(_x, _y, _z, _a, _b, _c) {
  if (!currentSection.isOptimizedForMachine()) {
    error(localize("This post configuration has not been customized for 5-axis simultaneous toolpath."));
    return;
  }
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation mode cannot be changed at rapid traversal."));
    return;
  }
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var a = aOutput.format(_a);
  var b = bOutput.format(_b);
  var c = cOutput.format(_c);
  writeBlock(gMotionModal.format(0), x, y, z, a, b, c);
  feedOutput.reset();
}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed) {
  if (!currentSection.isOptimizedForMachine()) {
    error(localize("This post configuration has not been customized for 5-axis simultaneous toolpath."));
    return;
  }
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for 5-axis move."));
    return;
  }
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var a = aOutput.format(_a);
  var b = bOutput.format(_b);
  var c = cOutput.format(_c);
  var f = feedOutput.format(feed);
  if (x || y || z || a || b || c) {
    writeBlock(gMotionModal.format(1), x, y, z, a, b, c, f);
  } else if (f) {
    if (getNextRecord().isMotion()) { // try not to output feed without motion
      feedOutput.reset(); // force feed on next line
    } else {
      writeBlock(gMotionModal.format(1), f);
    }
  }
}

function onCircular(clockwise, cx, cy, cz, x, y, z, feed) {
  if (pendingRadiusCompensation >= 0) {
    error(localize("Radius compensation cannot be activated/deactivated for a circular move."));
    return;
  }

  if (isFullCircle()) {
    if (properties.useRadius || isHelical()) { // radius mode does not support full arcs
      linearize(tolerance);
      return;
    }
    switch (getCircularPlane()) {
      case PLANE_XY:
        writeBlock(
          gAbsIncModal.format(90), iOutput.format(cx), jOutput.format(cy),
          gAbsIncModal.format(90), gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), feedOutput.format(feed)
        );
        break;
      case PLANE_ZX:
        writeBlock(
          gAbsIncModal.format(90), iOutput.format(cx), kOutput.format(cz),
          gAbsIncModal.format(90), gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), feedOutput.format(feed)
        );
        break;
      case PLANE_YZ:
        writeBlock(
          gAbsIncModal.format(90), jOutput.format(cy), kOutput.format(cz),
          gAbsIncModal.format(90), gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), feedOutput.format(feed)
        );
        break;
      default:
        linearize(tolerance);
    }
  } else if (!properties.useRadius) {
    switch (getCircularPlane()) {
      case PLANE_XY:
        writeBlock(
          gAbsIncModal.format(90), iOutput.format(cx), jOutput.format(cy),
          gAbsIncModal.format(90), gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), feedOutput.format(feed)
        );
        break;
      case PLANE_ZX:
        writeBlock(
          iOutput.format(cx), kOutput.format(cz),
          gAbsIncModal.format(90), gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), feedOutput.format(feed)
        );
        break;
      case PLANE_YZ:
        writeBlock(
          jOutput.format(cy), kOutput.format(cz),
          gAbsIncModal.format(90), gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), feedOutput.format(feed)
        );
        break;
      default:
        linearize(tolerance);
    }
  } else { // use radius mode
    var r = getCircularRadius();
    if (toDeg(getCircularSweep()) > (180 + 1e-9)) {
      r = -r; // allow up to <360 deg arcs
    }
    switch (getCircularPlane()) {
      case PLANE_XY:
        writeBlock(
          gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), "R" + rFormat.format(r), feedOutput.format(feed)
        );
        break;
      case PLANE_ZX:
        writeBlock(
          gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), "R" + rFormat.format(r), feedOutput.format(feed)
        );
        break;
      case PLANE_YZ:
        writeBlock(
          gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), "R" + rFormat.format(r), feedOutput.format(feed)
        );
        break;
      default:
        linearize(tolerance);
    }
  }
}

var currentCoolantMode;

function setCoolant(coolant) {
  if (coolant == currentCoolantMode) {
    return; // coolant is already active
  }

  var m = undefined;
  switch (coolant) {
    case COOLANT_OFF:
      m = 9;
      break;
    case COOLANT_FLOOD:
      m = 8;
      break;
    default:
      warning(localize("Coolant not supported."));
      if (currentCoolantMode == COOLANT_OFF) {
        return;
      }
      coolant = COOLANT_OFF;
      m = 9;
  }

  writeBlock(mFormat.format(m));
  currentCoolantMode = coolant;
}

var mapCommand = {
  COMMAND_STOP: 0,
  COMMAND_OPTIONAL_STOP: 1,
  COMMAND_END: 2,
  COMMAND_SPINDLE_CLOCKWISE: 3,
  COMMAND_SPINDLE_COUNTERCLOCKWISE: 4,
  COMMAND_STOP_SPINDLE: 5,
  COMMAND_ORIENTATE_SPINDLE: 19,
  COMMAND_LOAD_TOOL: 6
};

function onCommand(command) {
  switch (command) {
    case COMMAND_COOLANT_ON:
      setCoolant(COOLANT_FLOOD);
      return;
    case COMMAND_COOLANT_OFF:
      setCoolant(COOLANT_OFF);
      return;
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
  writeBlock(gPlaneModal.format(17));
  forceAny();
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
  var block = "";
  for (var i = 0; i < arguments.length; ++i) {
    switch (arguments[i]) {
      case X:
        block += "X" + xyzFormat.format(machineConfiguration.hasHomePositionX() ? machineConfiguration.getHomePositionX() : 0) + " ";
        break;
      case Y:
        block += "Y" + xyzFormat.format(machineConfiguration.hasHomePositionY() ? machineConfiguration.getHomePositionY() : 0) + " ";
        break;
      case Z:
        block += "Z" + xyzFormat.format(machineConfiguration.getRetractPlane()) + " ";
        retracted = true; // specifies that the tool has been retracted to the safe plane
        break;
      default:
        error(localize("Bad axis specified for writeRetract()."));
        return;
    }
  }
  gMotionModal.reset();
  if (block) {
    writeBlock(gMotionModal.format(0), gFormat.format(40), gAbsIncModal.format(90), block + mFormat.format(properties.useM92 ? 92 : 91));
  }
  zOutput.reset();
}

function onClose() {
  onCommand(COMMAND_COOLANT_OFF);

  writeRetract(Z);

  if (properties.homeXYAtEnd) {
    writeRetract(X, Y);
  }

  setWorkPlane(new Vector(0, 0, 0)); // reset working plane

  onImpliedCommand(COMMAND_END);
  onImpliedCommand(COMMAND_STOP_SPINDLE);
  writeBlock(mFormat.format(30)); // stop program, spindle stop, coolant off

  writeBlock("%" + programName, gUnitModal.format((unit == MM) ? 71 : 70));
}
