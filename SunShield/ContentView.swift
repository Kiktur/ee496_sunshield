//
//  ContentView.swift
//  Sun Shield
//
//  Created by Victoria Aguirre on 4/7/26.
//

import SwiftUI
import CoreBluetooth
import Combine

// Manages the Bluetooth connection, incoming wearable data, and settings sent to the wearable.
final class BluetoothManager: NSObject, ObservableObject {
    // Published properties automatically update the SwiftUI interface when their values change.
    @Published var isBluetoothPoweredOn = false
    @Published var isConnected = false
    @Published var deviceName = "Not Connected"
    @Published var connectionStatusText = "Disconnected"

    // Live sensor values received from the wearable.
    @Published var currentUV: Double = 0.0
    @Published var timeRemainingMinutes: Int = 0
    @Published var batteryLevel: Int = 0

    // Tracks whether settings were sent successfully to the wearable.
    @Published var settingsSyncStatus = ""
    @Published var didReceiveSettingsAck = false

    // CoreBluetooth objects used to scan for, connect to, and communicate with the wearable.
    private var centralManager: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?

    // RX characteristics are used to send information from the app to the wearable.
    private var rxSPFCharacteristic: CBCharacteristic?
    private var rxSkinCharacteristic: CBCharacteristic?

    // TX characteristics are used to receive live data from the wearable.
    private var txUVCharacteristic: CBCharacteristic?
    private var txMinutesCharacteristic: CBCharacteristic?
    private var txBatteryCharacteristic: CBCharacteristic?

    // UUIDs identify the Bluetooth service and characteristics used by the SunShield device.
    private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")

    private let rxSPFUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxSkinUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    private let txUVUUID = CBUUID(string: "6E400005-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txMinutesUUID = CBUUID(string: "6E400006-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txBatteryUUID = CBUUID(string: "6E400007-B5A3-F393-E0A9-E50E24DCCA9E")
    
    // Exposure limit table used to estimate sunscreen reapplication time.
    private let limits = [
        [120, 60, 40, 20, 10],
        [120, 80, 60, 30, 20],
        [180, 100, 80, 40, 30],
        [180, 120, 100, 60, 40],
        [200, 140, 120, 80, 60]
    ]

    // Converts a UV index value into the correct column for the exposure limit table.
    private func uvColumn(for uv: Double) -> Int {
        if uv < 3 { return 0 }
        if uv < 6 { return 1 }
        if uv < 8 { return 2 }
        if uv < 11 { return 3 }
        return 4
    }

    // Calculates the estimated minutes remaining based on sensor counter, skin type, SPF, and UV level.
    private func calculateMinutesRemaining(counter: Float, skinType: Int = 2, spf: Int = 30) -> Int {
        let skinIndex = max(0, min(skinType - 1, limits.count - 1))
        let column = uvColumn(for: currentUV)

        let matrixVal = Double(limits[skinIndex][column]) * (Double(spf) / 30.0)
        let minutesLeft = (Double(counter) / 200.0) * matrixVal

        return max(0, Int(minutesLeft.rounded()))
    }

    // Initializes the Bluetooth central manager when the app starts.
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // Sends a string-encoded integer value to a specific Bluetooth characteristic.
    private func sendInteger(_ value: String, to characteristic: CBCharacteristic?) {
        guard let peripheral = discoveredPeripheral,
              let characteristic = characteristic,
              let data = value.data(using: .utf8) else { return }

        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    // Sends selected skin type and SPF settings to the connected wearable.
    func sendSettings(skin: Int, spf: Int) {
        didReceiveSettingsAck = false
        settingsSyncStatus = "Sending settings..."

        sendInteger("\(spf)", to: rxSPFCharacteristic)
        sendInteger("\(skin)", to: rxSkinCharacteristic)

        settingsSyncStatus = "Settings sent to wearable"
    }

    // Begins scanning for the SunShield Bluetooth device.
    func startScan() {
        guard centralManager.state == .poweredOn else {
            connectionStatusText = "Bluetooth Off"
            return
        }

        connectionStatusText = "Scanning..."
        deviceName = "Searching..."

        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    // Stops any active Bluetooth scan.
    func stopScan() {
        centralManager.stopScan()
    }

    // Disconnects from the currently connected wearable.
    func disconnect() {
        guard let peripheral = discoveredPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }
}

// Handles Bluetooth central manager events such as power state, discovery, connection, and disconnection.
extension BluetoothManager: CBCentralManagerDelegate {

    // Updates app state when the phone Bluetooth power/status changes.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isBluetoothPoweredOn = true
            connectionStatusText = "Ready to Scan"

        default:
            isBluetoothPoweredOn = false
            isConnected = false
            connectionStatusText = "Bluetooth Unavailable"
        }
    }

    // Called whenever a nearby Bluetooth peripheral is discovered during scanning.
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
            ?? "Unknown"

        print("Found:", name)

        guard name == "SunShield" else { return }

        stopScan()

        discoveredPeripheral = peripheral
        discoveredPeripheral?.delegate = self

        deviceName = name
        connectionStatusText = "Connecting..."

        centralManager.connect(peripheral, options: nil)
    }

    // Called after the app successfully connects to the wearable.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        deviceName = peripheral.name ?? "Connected"
        connectionStatusText = "Connected"

        peripheral.discoverServices([serviceUUID])
    }

    // Resets Bluetooth-related values after the wearable disconnects.
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        
        rxSPFCharacteristic = nil
        rxSkinCharacteristic = nil
        txUVCharacteristic = nil
        txMinutesCharacteristic = nil
        txBatteryCharacteristic = nil
        
        discoveredPeripheral = nil
        
        deviceName = "Not Connected"
        connectionStatusText = "Disconnected"
    }
}

// Handles services, characteristics, and incoming Bluetooth data from the wearable.
extension BluetoothManager: CBPeripheralDelegate {

    // Searches the connected peripheral for the SunShield service.
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {

        guard let services = peripheral.services else { return }

        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics(
                [rxSPFUUID, rxSkinUUID, txUVUUID, txMinutesUUID, txBatteryUUID],
                for: service
            )
        }
    }

    // Stores discovered characteristics and enables notifications for live data updates.
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {

        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            switch characteristic.uuid {

            case rxSPFUUID:
                rxSPFCharacteristic = characteristic

            case rxSkinUUID:
                rxSkinCharacteristic = characteristic

            case txUVUUID:
                txUVCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case txMinutesUUID:
                txMinutesCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            case txBatteryUUID:
                txBatteryCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)

            default:
                break
            }
        }

        connectionStatusText = "Ready"
    }

    // Reads updated wearable values and updates the app display.
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        guard let data = characteristic.value else { return }

        switch characteristic.uuid {

        case txBatteryUUID:
            batteryLevel = Int(data.first ?? 0)

        case txUVUUID:
            let uv = data.withUnsafeBytes {
                $0.loadUnaligned(as: Float.self)
            }
            currentUV = Double(uv)

        case txMinutesUUID:
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(as: Float.self)
            }
            timeRemainingMinutes = calculateMinutesRemaining(counter: value)

        default:
            break
        }
    }
}

// Main screen that displays UV level, countdown, exposure stats, recommendations, and Bluetooth controls.
struct ContentView: View {
    // Local view state for presenting the settings sheet.
    @State private var showSettings = false
    @StateObject private var bluetooth = BluetoothManager()

    // AppStorage saves user settings so they persist after the app closes.
    @AppStorage("savedSkinType") private var savedSkinType = "Type II"
    @AppStorage("savedSPF") private var savedSPF = "SPF 30"
    @AppStorage("savedCustomSPF") private var savedCustomSPF = "30"

    // Builds the main dashboard layout.
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 241/255, green: 244/255, blue: 250/255)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {

                        HeaderView(showSettings: $showSettings)

                        CurrentUVCard(uvValue: bluetooth.currentUV)

                        ReapplyCountdownCard(timeRemainingMinutes: bluetooth.timeRemainingMinutes)

                        HStack(spacing: 16) {
                            WeeklyAvgCard()
                            StreakCard()
                        }

                        HStack(spacing: 16) {
                            SkinTypeCard(
                                skinType: savedSkinType,
                                spf: savedSPF == "None"
                                    ? "No sunscreen"
                                    : savedSPF
                            )

                            PeakUVCard()
                        }

                        WeeklyExposureCard()

                        RecommendationsCard()

                        DeviceStatusCard(
                            isConnected: bluetooth.isConnected,
                            batteryLevel: bluetooth.batteryLevel
                        )

                        BluetoothControlsCard(bluetooth: bluetooth)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                    .frame(width: geo.size.width)
                }
            }

            .sheet(isPresented: $showSettings) {
                SettingsView(
                    bluetooth: bluetooth,
                    savedSkinType: $savedSkinType,
                    savedSPF: $savedSPF,
                    savedCustomSPF: $savedCustomSPF
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
    }
}

// Top header with the app title, subtitle, settings button, and sun icon button.
struct HeaderView: View {
    @Binding var showSettings: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sun Guard")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Stay protected")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(
                        Color(red: 109/255, green: 117/255, blue: 136/255)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 12)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(
                        Color(red: 109/255, green: 117/255, blue: 136/255)
                    )
                    .frame(width: 44, height: 44)
            }

            Button {
                print("Sun tapped")
            } label: {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.orange)
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "sun.max")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

// Card that displays the current UV index, risk label, and progress bar.
struct CurrentUVCard: View {
    let uvValue: Double

    // Converts the numeric UV value into a readable UV risk label.
    private var uvLabel: String {
        switch uvValue {
        case 0..<3: return "Low"
        case 3..<6: return "Moderate"
        case 6..<8: return "High"
        case 8..<11: return "Very High"
        default: return "Extreme"
        }
    }

    // Chooses the display color based on the current UV risk category.
    private var uvColor: Color {
        switch uvValue {
        case 0..<3: return .green
        case 3..<6: return .yellow
        case 6..<8: return .orange
        case 8..<11: return .red
        default: return .purple
        }
    }

    // Converts the UV value into a 0-to-1 progress value for the progress bar.
    private var uvProgress: CGFloat {
        min(CGFloat(uvValue / 11.0), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {

            HStack(alignment: .top) {
                Text("Current UV Index")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(
                        Color(red: 103/255, green: 111/255, blue: 130/255)
                    )

                Spacer()

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(uvColor)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(String(format: "%.1f", uvValue))
                    .font(.system(size: 64, weight: .medium))
                    .foregroundColor(.black)

                Text(uvLabel)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(uvColor)
            }

            ProgressBar(
                progress: uvProgress,
                fillColor: uvColor,
                backgroundColor: Color.gray.opacity(0.25)
            )
            .frame(height: 14)

            Text("Live from wearable")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(
                    Color(red: 150/255, green: 158/255, blue: 174/255)
                )
        }
        .padding(24)
        .background(CardBackground())
        .clipShape(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Card that shows how many minutes remain before sunscreen should be reapplied.
struct ReapplyCountdownCard: View {
    let timeRemainingMinutes: Int

    private var progressValue: CGFloat {
        min(CGFloat(timeRemainingMinutes) / 200.0, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 22))
                    .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))

                Text("Reapply Countdown")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(timeRemainingMinutes)")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundColor(.black)

                Text("min left")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))
            }

            ProgressBar(
                progress: progressValue,
                fillColor: timeRemainingMinutes <= 10 ? .red : .orange,
                backgroundColor: timeRemainingMinutes <= 10
                    ? Color.red.opacity(0.15)
                    : Color.orange.opacity(0.15)
            )
            .frame(height: 16)

            if timeRemainingMinutes <= 0 {
                Text("⚠️ Reapply sunscreen now")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.red)
            } else if timeRemainingMinutes <= 10 {
                Text("Almost time to reapply")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
            } else {
                Text("Sunscreen protection time remaining")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.green)
            }
        }
        .padding(24)
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Small card showing the weekly average exposure statistic.
struct WeeklyAvgCard: View {
    var body: some View {
        SmallStatCard(
            icon: "arrow.up.right",
            iconColor: .blue,
            value: "115 min",
            title: "Weekly Avg",
            subtitle: "+12% from last week"
        )
    }
}

// Small card showing the user's current protection streak.
struct StreakCard: View {
    var body: some View {
        SmallStatCard(
            icon: "calendar",
            iconColor: .blue,
            value: "5 days",
            title: "Streak",
            subtitle: "Stay safe!"
        )
    }
}

// Reusable card layout for compact statistics.
struct SmallStatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 235/255, green: 240/255, blue: 248/255))
                    .frame(width: 74, height: 74)

                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(iconColor)
            }

            Text(value)
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(.black)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(
                        Color(red: 103/255, green: 111/255, blue: 130/255)
                    )

                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(
                        Color(red: 148/255, green: 156/255, blue: 172/255)
                    )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(CardBackground())
        .clipShape(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Displays the selected skin type and SPF setting.
struct SkinTypeCard: View {
    let skinType: String
    let spf: String

    var body: some View {
        InfoCard(
            icon: "drop",
            iconColor: .blue,
            bigText: skinType,
            title: "Skin Type",
            subtitle: spf
        )
    }
}

// Displays the peak UV value for the day.
struct PeakUVCard: View {
    var body: some View {
        InfoCard(
            icon: "sun.max",
            iconColor: .blue,
            bigText: "8.2",
            title: "Peak UV",
            subtitle: "Today at 1:30 PM"
        )
    }
}

// Reusable information card used for skin type and peak UV sections.
struct InfoCard: View {
    let icon: String
    let iconColor: Color
    let bigText: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 235/255, green: 240/255, blue: 248/255))
                    .frame(width: 74, height: 74)

                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(iconColor)
            }

            Spacer(minLength: 0)

            Text(bigText)
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(.black)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(
                        Color(red: 103/255, green: 111/255, blue: 130/255)
                    )

                Text(subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(
                        Color(red: 148/255, green: 156/255, blue: 172/255)
                    )
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(CardBackground())
        .clipShape(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Bar chart card showing weekly UV exposure values.
struct WeeklyExposureCard: View {
    let values: [CGFloat] = [90, 105, 80, 130, 70, 155, 140]
    let labels: [String] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Today"]
    let overLimitDays: Set<Int> = [3, 5, 6]

    private let maxValue: CGFloat = 160
    private let chartHeight: CGFloat = 170
    private let axisWidth: CGFloat = 34
    private let barWidth: CGFloat = 34
    private let barSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            Text("Weekly Exposure")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.black)

            HStack(alignment: .bottom, spacing: 12) {

                // Y-axis labels
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach([160, 120, 80, 40, 0], id: \.self) { tick in
                        Text("\(tick)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(
                                Color(red: 150/255, green: 158/255, blue: 174/255)
                            )
                            .frame(height: chartHeight / 4, alignment: .bottom)
                    }
                }
                .frame(width: axisWidth, height: chartHeight, alignment: .bottom)

                // Bars
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(0..<values.count, id: \.self) { index in
                            VStack(spacing: 10) {

                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        overLimitDays.contains(index)
                                        ? Color.red
                                        : Color.blue
                                    )
                                    .frame(
                                        width: barWidth,
                                        height: max(
                                            12,
                                            (values[index] / maxValue) * chartHeight
                                        )
                                    )

                                Text(labels[index])
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(
                                        Color(red: 150/255, green: 158/255, blue: 174/255)
                                    )
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(width: barWidth + 8)
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
                .frame(height: chartHeight + 28)
            }

            // Legend
            HStack(spacing: 34) {

                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 14, height: 14)

                    Text("Safe")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(
                            Color(red: 103/255, green: 111/255, blue: 130/255)
                        )
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 14, height: 14)

                    Text("Over Limit")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(
                            Color(red: 103/255, green: 111/255, blue: 130/255)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
        .padding(24)
        .background(CardBackground())
        .clipShape(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
    }
}

// Gradient card showing protection recommendations based on UV conditions.
struct RecommendationsCard: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 69/255, green: 127/255, blue: 238/255),
                    Color(red: 172/255, green: 69/255, blue: 243/255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "shield")
                        .font(.system(size: 24, weight: .medium))

                    Text("Recommendations")
                        .font(.system(size: 22, weight: .medium))
                }

                Text("High UV levels. Protection required.")
                    .font(.system(size: 22, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 18) {
                    RecommendationRow(icon: "shield", text: "Apply SPF 50+ sunscreen")
                    RecommendationRow(icon: "tshirt", text: "Wear protective clothing")
                    RecommendationRow(icon: "eyeglasses", text: "Avoid sun 10 AM - 4 PM")
                }
            }
            .foregroundColor(.white)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .clipShape(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
        )
        .shadow(color: .black.opacity(0.08), radius: 18, x: 0, y: 10)
    }
}

// Debug card with scan and disconnect controls for Bluetooth testing.
struct BluetoothControlsCard: View {
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bluetooth Debug")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.black)

            Text("Status: \(bluetooth.connectionStatusText)")
                .foregroundColor(.gray)

            Text("Device: \(bluetooth.deviceName)")
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                Button {
                    bluetooth.startScan()
                } label: {
                    Text("Scan")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }

                Button {
                    bluetooth.disconnect()
                } label: {
                    Text("Disconnect")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.red.opacity(0.9))
                        .foregroundColor(.white)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
            }
        }
        .padding(24)
        .background(CardBackground())
        .clipShape(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Single recommendation row with an icon and description.
struct RecommendationRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 54, height: 54)

                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white)
            }

            Text(text)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
        }
    }
}

// Shows whether the wearable is connected and displays the battery percentage.
struct DeviceStatusCard: View {
    let isConnected: Bool
    let batteryLevel: Int
    var body: some View {
        HStack {
            HStack(spacing: 14) {
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 16, height: 16)

                Text(isConnected ? "Device Connected" : "Device Disconnected")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Color(red: 76/255, green: 87/255, blue: 106/255))
            }

            Spacer()

            Text("Battery \(batteryLevel)%")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color(red: 150/255, green: 158/255, blue: 174/255))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

// Reusable horizontal progress bar used by UV and countdown cards.
struct ProgressBar: View {
    var progress: CGFloat
    var fillColor: Color
    var backgroundColor: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(backgroundColor)

                Capsule()
                    .fill(fillColor)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

// Shared white card background style.
struct CardBackground: View {
    var body: some View {
        Color.white.opacity(0.92)
    }
}

// Selectable card used for choosing a Fitzpatrick skin type in settings.
struct SkinTypeOptionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.black)

                    Text(subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if isSelected {
                    ZStack {
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 42, height: 42)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .background(isSelected ? Color.purple.opacity(0.08) : Color.white.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        isSelected ? Color.purple : Color.gray.opacity(0.18),
                        lineWidth: isSelected ? 3 : 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Selectable button used for choosing an SPF value in settings.
struct SPFOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 78)
                .background(isSelected ? Color.blue.opacity(0.10) : Color.white.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            isSelected ? Color.blue : Color.gray.opacity(0.18),
                            lineWidth: isSelected ? 3 : 1.5
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// Settings sheet where the user selects skin type and sunscreen SPF.
struct SettingsView: View {
    // Dismiss action closes the settings sheet.
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var bluetooth: BluetoothManager
    @Binding var savedSkinType: String
    @Binding var savedSPF: String
    @Binding var savedCustomSPF: String

    // Temporary setting values used while the settings sheet is open.
    @State private var selectedSkinType: String = "Type II"
    @State private var selectedSPF: String = "SPF 30"
    @State private var customSPF: String = "30"

    @State private var showSyncAlert = false

    // Skin type choices shown in the settings screen.
    let skinTypes: [(title: String, subtitle: String)] = [
        ("Type I", "Very fair, always burns"),
        ("Type II", "Fair, usually burns"),
        ("Type III", "Medium, sometimes burns"),
        ("Type IV", "Olive, rarely burns"),
        ("Type V", "Brown, very rarely burns"),
        ("Type VI", "Dark brown, never burns")
    ]

    // Preset SPF options shown in the settings screen.
    let spfOptions = ["None", "SPF 15", "SPF 30", "SPF 50", "SPF 70", "SPF 100"]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 247/255, green: 247/255, blue: 250/255)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                settingsHeader

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        skinTypeSection
                        sunscreenSection
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 26)
                    .padding(.bottom, 120)
                }
            }

            bottomSaveBar
        }
        .onAppear {
            selectedSkinType = savedSkinType
            selectedSPF = savedSPF
            customSPF = savedCustomSPF
        }
        .alert(bluetooth.settingsSyncStatus, isPresented: $showSyncAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    // Converts the selected skin type label into the number sent to the wearable.
    private func skinTypeNumber(from type: String) -> Int {
        switch type {
        case "Type I": return 1
        case "Type II": return 2
        case "Type III": return 3
        case "Type IV": return 4
        case "Type V": return 5
        case "Type VI": return 6
        default: return 2
        }
    }

    // Converts the selected/custom SPF value into the integer sent to the wearable.
    private var spfValueToSend: Int {
        if selectedSPF == "None" {
            return 0
        }

        if let custom = Int(customSPF.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return custom
        }

        return Int(selectedSPF.replacingOccurrences(of: "SPF ", with: "")) ?? 0
    }

    // Header section for the settings sheet.
    private var settingsHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 56, height: 56)

                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(Color.purple)
            }

            Text("Settings")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.black)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.black)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 20)
        .background(Color.white.opacity(0.7))
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // Section that lets the user choose their Fitzpatrick skin type.
    private var skinTypeSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "sun.max")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.orange)

                Text("Skin Type")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.black)
            }

            Text("Select your Fitzpatrick skin type to personalize UV exposure recommendations")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 16) {
                ForEach(skinTypes, id: \.title) { skin in
                    SkinTypeOptionCard(
                        title: skin.title,
                        subtitle: skin.subtitle,
                        isSelected: selectedSkinType == skin.title
                    ) {
                        selectedSkinType = skin.title
                    }
                }
            }
        }
    }

    // Section that lets the user choose or type an SPF value.
    private var sunscreenSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "shield")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.blue)

                Text("Sunscreen SPF")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.black)
            }

            Text("What SPF sunscreen are you currently wearing?")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(red: 103/255, green: 111/255, blue: 130/255))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(spfOptions, id: \.self) { option in
                    SPFOptionButton(
                        title: option,
                        isSelected: selectedSPF == option
                    ) {
                        selectedSPF = option
                        if option != "None" {
                            customSPF = option.replacingOccurrences(of: "SPF ", with: "")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Or enter custom SPF:")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(red: 76/255, green: 87/255, blue: 106/255))

                TextField("30", text: $customSPF)
                    .keyboardType(.numberPad)
                    .font(.system(size: 20, weight: .medium))
                    .padding(.horizontal, 20)
                    .frame(height: 64)
                    .background(Color.black.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    // Bottom save button that stores settings and sends them to the wearable when connected.
    private var bottomSaveBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
                .frame(height: 1)

            Button {
                guard bluetooth.isConnected else {
                    bluetooth.settingsSyncStatus = "Wearable not connected"
                    showSyncAlert = true
                    return
                }

                savedSkinType = selectedSkinType
                savedSPF = spfValueToSend == 0 ? "None" : "SPF \(spfValueToSend)"
                savedCustomSPF = customSPF

                let skin = skinTypeNumber(from: selectedSkinType)
                let spf = spfValueToSend

                bluetooth.sendSettings(skin: skin, spf: spf)

                dismiss()
            } label: {
                LinearGradient(
                    colors: [
                        Color(red: 174/255, green: 72/255, blue: 242/255),
                        Color(red: 54/255, green: 124/255, blue: 240/255)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 64)
                .overlay(
                    Text("Save Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .background(.ultraThinMaterial)
        }
    }
}

// Xcode preview for quickly viewing ContentView during development.
#Preview {ContentView()}
