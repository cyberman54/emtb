using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.BluetoothLowEnergy as Ble;
using Toybox.Application;
using Application.Properties as applicationProperties;
using Application.Storage as applicationStorage;


class emtbView extends WatchUi.DataField {
    // set true to enable debugging and mookup BLE
    private const debugging = false;

    private var thisView;               // reference to self, lovely
    private var bleHandler;             // the BLE delegate
    
    private var showList = [];          // 3 user settings for which values to show
    var lastLock = false;               // user setting for lock to MAC address (or not)
    var lastMACArray = null;            // byte array of MAC address of bike
    
    var values = {  // The values are read from BLE
        1 => -1, // battery available
        3 => -1, // mode number
        6 => -1, // gear
        7 => -1, // cadence
        8 => -1, // assistance level
        9 => -1  // current speed
    };

    private var labelsDict = {  // The labels shown near the values
        0 => WatchUi.loadResource(Rez.Strings.LabelOff),
        1 => WatchUi.loadResource(Rez.Strings.LabelBatteryAvailable),
        2 => WatchUi.loadResource(Rez.Strings.LabelBatteryConsumed),
        3 => WatchUi.loadResource(Rez.Strings.LabelModeNumber),
        4 => WatchUi.loadResource(Rez.Strings.LabelModeName),
        5 => WatchUi.loadResource(Rez.Strings.LabelModeLetter),
        6 => WatchUi.loadResource(Rez.Strings.LabelGear),
        7 => WatchUi.loadResource(Rez.Strings.LabelCadence),
        8 => WatchUi.loadResource(Rez.Strings.LabelAssistanceLevel),
        9 => WatchUi.loadResource(Rez.Strings.LabelSpeed)
    };

    private const padding = 20;

    private const secondsWaitBattery = 15;  // only read the battery value every 15 seconds
    private var secondsSinceReadBattery = secondsWaitBattery;

    private var modeNames = [
        "Off",
        "Eco",
        "Trail",
        "Boost",
        "Walk",
    ];

    private var modeLetters = [
        "O",
        "E",
        "T",
        "B",
        "W",
    ];

    private var connectCounter = 0; // number of seconds spent scanning/connecting to a bike

    // Safely read a boolean value from user settings
    function propertiesGetBoolean(p)
    {
        var v = applicationProperties.getValue(p);
        if ((v == null) || !(v instanceof Boolean))
        {
            v = false;
        }
        return v;
    }
    
    // Safely read a number value from user settings
    function propertiesGetNumber(p)
    {
        var v = applicationProperties.getValue(p);
        if ((v == null) || (v instanceof Boolean))
        {
            v = 0;
        }
        else if (!(v instanceof Number))
        {
            v = v.toNumber();
            if (v == null)
            {
                v = 0;
            }
        }
        return v;
    }

    // Safely read a string value from user settings
    function propertiesGetString(p)
    {   
        var v = applicationProperties.getValue(p);
        if (v == null)
        {
            v = "";
        }
        else if (!(v instanceof String))
        {
            v = v.toString();
        }
        return v;
    }

    // read the user settings and store locally
    function getUserSettings()
    {
        // Add the values to showList
        showList = [];
        for (var i=1; i<=4; i++)
        {
            if(propertiesGetNumber("Item" + i.toString()) != 0)
            {
                showList.add(propertiesGetNumber("Item" + i.toString()));
            }
        }
        System.println("Showing list " + showList.toString());
        
        lastLock = propertiesGetBoolean("LastLock");
        
        // convert the MAC address string to a byte array
        // (if the string is an invalid format, e.g. contains the letter Z, then the byte array will be null)
        lastMACArray = null;
        var lastMAC = propertiesGetString("LastMAC");
        try
        {
            if (lastMAC.length()>0)
            {
                lastMACArray = StringUtil.convertEncodedString(lastMAC, {:fromRepresentation => StringUtil.REPRESENTATION_STRING_HEX, :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY});
            }
        }
        catch (e)
        {
            //System.println("err");
            lastMACArray = null;
        }
    }

    // Remember the current MAC address byte array, and also convert it to a string and store in the user settings 
    function saveLastMACAddress(newMACArray)
    {
        if (newMACArray!=null)
        {
            lastMACArray = newMACArray;
            try
            {
                var s = StringUtil.convertEncodedString(newMACArray, {:fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY, :toRepresentation => StringUtil.REPRESENTATION_STRING_HEX});
                applicationProperties.setValue("LastMAC", s.toUpper());
            }
            catch (e)
            {
                //System.println("err");
            }
        }
    }

    function initialize() {
        System.println("Initializing...");
        if(debugging)
        {
            System.println("Setting debugging props...");
            // quick test values
            applicationProperties.setValue("Item1", 2);
            applicationProperties.setValue("Item2", 0);
            applicationProperties.setValue("Item3", 1);
            applicationProperties.setValue("Item4", 0);
        }

        DataField.initialize();
        getUserSettings();
    }

    // remember a reference to ourself as it's useful, but can't see a way in CIQ to access this otherwise?! 
    function setSelf(theView)
    {
        thisView = theView;

        if(debugging)
        {
            setupMookupBle();
        } else
        {
            setupBle();
        }
    }

    function setupMookupBle()
    {
        bleHandler = new $.emtbDelegateMookup(thisView);
    }
    
    function setupBle()
    {
        bleHandler = new $.emtbDelegate(thisView);
        Ble.setDelegate(bleHandler);
    }

    // called by app when settings change
    function onSettingsChanged()
    {
        getUserSettings();
    
        // do some stuff in case user has changed the MAC address or the lock flag
        if (bleHandler!=null)
        {
            // if lastLock or lastMAC get changed dynamically while the field is running then should check if current bike connection is ok
            if (lastLock && lastMACArray!=null && bleHandler.connectedMACArray!=null && !bleHandler.sameMACArray(lastMACArray, bleHandler.connectedMACArray))
            {
                bleHandler.bleDisconnect();
            }
    
            // And lets clear the scanned list, as if a device was scanned and excluded previously, maybe now it shouldn't be
            bleHandler.deleteScannedList();
        }

        WatchUi.requestUpdate();   // update the view to reflect changes
    }

    // The given info object contains all the current workout information.
    // Calculate a value and save it locally in this method.
    // Note that compute() and onUpdate() are asynchronous, and there is no
    // guarantee that compute() will be called before onUpdate().
    function compute(info as Activity.Info) as Void {
        // battery fields
        var showBattery = false;
        for (var i = 0; i < showList.size(); i++)
        {
            if (showList[i] == 1 || showList[i] == 2)
            {
                showBattery = true;
            }
        }
        if (showBattery)
        {
            // only read battery value every 15 seconds once we have a value
            secondsSinceReadBattery++;
            if (values[1]<0 || secondsSinceReadBattery>=secondsWaitBattery)
            {
                secondsSinceReadBattery = 0;
                bleHandler.requestReadBattery();
            }
        }
        
        // other fields
        var showMode = false;
        for (var i = 0; i < showList.size(); i++)
        {
            if (showList[i] >= 3)
            {
                showMode = true;
            }
        }
        // set whether we want mode or not (continuously)
        bleHandler.requestNotifyMode(showMode);
    
        bleHandler.compute();
    }

    function getForegroundColor() as Graphics.ColorType
    {
        var color;
        if (getBackgroundColor() == Graphics.COLOR_BLACK)
        {
            color = Graphics.COLOR_WHITE;
        } 
        else
        {
            color = Graphics.COLOR_BLACK;
        }
        return color;
    }

    // Draw the labels on the screen
    function drawLabels(dc as Dc)
    {
        var numActiveValues = showList.size();
        var x = 0.0f;
        var y = dc.getHeight() / 2 - 1.2 * dc.getFontHeight(Graphics.FONT_XTINY);
        var offset = (dc.getWidth() - 2 * padding) / numActiveValues / 2;
        dc.setColor(getForegroundColor(), Graphics.COLOR_TRANSPARENT);
        
        System.println("Drawing " + numActiveValues.toString() + " labels");
        for (var i=0; i<numActiveValues; i++)
        {
            x = ((dc.getWidth() - 2 * padding) * i / numActiveValues) + offset + padding;
            dc.drawText(
                x,
                y,
                Graphics.FONT_XTINY,
                labelsDict[showList[i]],
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }
    }

    // Draw the labels on the screen
    function drawValues(dc as Dc)
    {
        var numActiveValues = showList.size();
        var x = 0.0f;
        var y = dc.getHeight() / 2 - dc.getFontHeight(Graphics.FONT_LARGE) / 3;
        var offset = (dc.getWidth() - 2 * padding) / numActiveValues / 2;
        dc.setColor(getForegroundColor(), Graphics.COLOR_TRANSPARENT);
        
        System.println("Drawing " + numActiveValues.toString() + " values");
        for (var i=0; i<numActiveValues; i++)
        {
            x = ((dc.getWidth() - 2 * padding) * i / numActiveValues) + offset + padding;
            dc.drawText(
                x,
                y,
                Graphics.FONT_LARGE,
                computeValueString(showList[i]),
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }
    }

    // Draw large centered text
    function drawText(dc as Dc, msg as Lang.String)
    {
        dc.setColor(getForegroundColor(), Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() / 2 - dc.getFontHeight(Graphics.FONT_LARGE) / 2,
            Graphics.FONT_LARGE,
            msg,
            Graphics.TEXT_JUSTIFY_CENTER
        );
    }

    // Return a string for the required valueIndex
    function computeValueString(valueIndex)
    {
        var retString = "-";
        // battery available, mode number, gear, cadence, assistance level
        if (valueIndex == 1 || valueIndex == 3 || valueIndex == 6 || valueIndex == 7 || valueIndex == 8)
        {
            retString = (values[valueIndex]>=0) ? values[valueIndex].toString() : "-";
        }
        else if(valueIndex == 9)    // speed
        {
            retString = (values[valueIndex]>=0) ? values[valueIndex].format("%.1f").toString() : "-";
        }
        else if (valueIndex == 2)   // battery consumed
        {
            retString = (values[1]>=0) ? (100 - values[1]).toString() : "-";
        }
        else if (valueIndex == 4)   // mode name
        {   
            retString = (values[3]>=0) ? modeNames[values[3]] : "-";
        }
        else if (valueIndex == 5)   // mode letter
        {
            retString = (values[3]>=0) ? modeLetters[values[3]] : "-";
        }
        return retString;
    }

    // Display the value you computed here. This will be called
    // once a second when the data field is visible.
    function onUpdate(dc as Dc) as Void {
        System.println("Updating...");

        // could show status of scanning & pairing if we wanted
        if (bleHandler.isConnecting())
        {
            if (!bleHandler.isRegistered())
            {
                drawText(dc, "BLE Start");
            }
            else
            {
                connectCounter++;
                drawText(dc, "Scan " + connectCounter.toString());
            }
            
        } else
        {
            drawLabels(dc);
            drawValues(dc);
        }
    }
}
