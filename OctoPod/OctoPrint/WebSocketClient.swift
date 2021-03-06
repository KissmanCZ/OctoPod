import Foundation
import Starscream

// Classic websocket client that connects to "<octoprint>/sockjs/websocket"
// To receive socket events and received messages, create a WebSocketClientDelegate
// and add it as a delegate of this WebSocketClient
class WebSocketClient : NSObject, WebSocketDelegate {
    var serverURL: String!
    var apiKey: String!
    var username: String?
    var password: String?
    
    var socket: WebSocket?
    var socketRequest: URLRequest?
    
    // Keep track if we have an opened websocket connection
    var active: Bool = false
    var connecting: Bool = false
    var openRetries: Int = -1;
    var parseFailures: Int = 0;
    var closedByUser: Bool = false

    var heartbeatTimer : Timer?
    
    var delegate: WebSocketClientDelegate?

    init(printer: Printer) {
        super.init()
        serverURL = printer.hostname
        apiKey = printer.apiKey
        username = printer.username
        password = printer.password
        
        let urlString: String = "\(serverURL!)/sockjs/websocket"
        
        self.socketRequest = URLRequest(url: URL(string: urlString)!)
        self.socketRequest!.timeoutInterval = 5
        if username != nil && password != nil {
            // Add authorization header
            let plainData = (username! + ":" + password!).data(using: String.Encoding.utf8)
            let base64String = plainData!.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
            self.socketRequest!.setValue("Basic " + base64String, forHTTPHeaderField: "Authorization")
        }
        self.socket = WebSocket(request: self.socketRequest!)
        
        // Add as delegate of Websocket
        socket!.delegate = self
        // Establish websocket connection
        self.establishConnection()
    }

    // MARK: - WebSocketDelegate

    func websocketDidConnect(socket: Starscream.WebSocketClient) {
        active = true
        connecting = false
        openRetries = 0
        closedByUser = false
        
        heartbeatTimer = Timer.scheduledTimer(timeInterval: 40, target: self, selector: #selector(sendHeartbeat), userInfo: nil, repeats: true)
        heartbeatTimer?.fire()
        
        NSLog("Websocket CONNECTED - \(self.hash)")
        if let listener = delegate {
            listener.websocketConnected()
        }
    }
    
    func websocketDidDisconnect(socket: Starscream.WebSocketClient, error: Error?) {
        active = false
        connecting = false
        // Stop heatbeat timer
        heartbeatTimer?.invalidate()
        
        if let _ = error {
            // Retry up to 5 times to open a websocket connection
            if !closedByUser {
                if openRetries < 6 {
                    recreateSocket()
                    establishConnection()
                } else {
                    NSLog("Websocket disconnected. Error: \(String(describing: error?.localizedDescription)) - \(self.hash)")
                    if let listener = delegate {
                        listener.websocketConnectionFailed(error: error!)
                    }
                }
            } else {
                NSLog("Websocket disconnected - \(self.hash)")
            }
        }
    }
    
    func websocketDidReceiveMessage(socket: Starscream.WebSocketClient, text: String) {
        if let listener = delegate {
            do {
                if let json = try JSONSerialization.jsonObject(with: text.data(using: String.Encoding.utf8)!, options: [.mutableLeaves, .mutableContainers]) as? NSDictionary {
                    // Reset counter of parse failures
                    parseFailures = 0
                    if let current = json["current"] as? NSDictionary {
//                        NSLog("Websocket current state received: \(json)")
                        let event = CurrentStateEvent()
                        
                        if let state = (current["state"] as? NSDictionary) {
                            event.parseState(state: state)
                        }
                        
                        if let temps = current["temps"] as? NSArray {
                            if temps.count > 0 {
                                if let tempFirst = temps[0] as? NSDictionary {
                                    event.parseTemps(temp: tempFirst)
                                }
                            }
                        }
                        
                        event.currentZ = current["currentZ"] as? Double
                        
                        if let progress = current["progress"] as? NSDictionary {
                            event.parseProgress(progress: progress)
                        }
                        
                        if let logs = current["logs"] as? NSArray {
                            event.parseLogs(logs: logs)
                        }

                        listener.currentStateUpdated(event: event)
                    } else if let event = json["event"] as? NSDictionary {
                        // Check if settings were updated
                        if let type = event["type"] as? String {
                            if type == "SettingsUpdated" {
                                listener.octoPrintSettingsUpdated()
                            } else if type == "TransferDone" || type == "TransferFailed" {
                                // Events denoting that upload to SD card is done or was cancelled
                                let event = CurrentStateEvent()
                                event.printing = false
                                event.progressCompletion = 100
                                event.progressPrintTimeLeft = 0
                                // Notify listener
                                listener.currentStateUpdated(event: event)
                            } else if type == "PrinterStateChanged" {
                                if let payload =  event["payload"] as? NSDictionary {
                                    if let state_id = payload["state_id"] as? String, let state_string = payload["state_string"] as? String {
                                        var event: CurrentStateEvent?
                                        if state_id == "PRINTING" {
                                            // Event indicating that printer is busy. Could be printing or uploading file to SD Card
                                            event = CurrentStateEvent()
                                            event!.printing = true
                                            event!.state = state_string
                                        } else if state_id == "OPERATIONAL" {
                                            // Event indicating that printer is ready to be used
                                            event = CurrentStateEvent()
                                            event!.printing = false
                                            event!.state = state_string
                                        }
                                        if let _ = event {
                                            // Notify listener
                                            listener.currentStateUpdated(event: event!)
                                        }
                                    }
                                }
                            }
                        }
                    } else if let history = json["history"] as? NSDictionary {
                        if let temps = history["temps"] as? NSArray {
                            var historyTemps = Array<TempHistory.Temp>()
                            for case let temp as NSDictionary in temps {
                                var historyTemp = TempHistory.Temp()
                                historyTemp.parseTemps(temp: temp)
                                historyTemps.append(historyTemp)
                            }
                            // Notify listener
                            listener.historyTemp(history: historyTemps)
                        }
                    } else if let plugin = json["plugin"] as? NSDictionary {
                        if let identifier = plugin["plugin"] as? String, let data = plugin["data"] as? NSDictionary {
                            // Notify listener
                            listener.pluginMessage(plugin: identifier, data: data)
                        }
                    } else {
//                        NSLog("Websocket message received: \(text)")
                    }
                }
            } catch {
                // Increment counter of parse failures
                parseFailures = parseFailures + 1
                NSLog("Error parsing websocket message: \(text)")
                NSLog("Parsing error: \(error)" )
                if parseFailures > 6 {
                    // If we had 6 consecutive parse failures then retry recreating the socket
                    // Websocket may be corrupted and needs to be recreated
                    recreateSocket()
                    establishConnection()
                } else if parseFailures > 12 {
                    // We keep failing so just close the connection
                    // and alert we are no longer connected
                    abortConnection(error: error)
                }
            }
        }
    }
    
    func websocketDidReceiveData(socket: Starscream.WebSocketClient, data: Data) {
        // Do nothing
        NSLog("Websocket received data - \(self.hash)")
    }
    
    // MARK: - Private functions

    func establishConnection() {
        if connecting {
            // Nothing to do
            return
        }
        connecting = true
        // Increment number of times we are trying to establish a websockets connection
        openRetries = openRetries + 1
        if openRetries > 0 {
            NSLog("Retrying websocket connection after \(openRetries * 300) milliseconds")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(openRetries * 300), execute: {
                // Try establishing the connection
                self.socket?.connect()
            })
        } else {
            // Try establishing the connection
            socket?.connect()
        }
    }
    
    func closeConnection() {
        openRetries = -1
        closedByUser = true
        socket?.disconnect()
    }
    
    func abortConnection(error: Error) {
        openRetries = -1
        closedByUser = false
        socket?.disconnect()

        NSLog("Websocket corrupted?. Error: \(String(describing: error.localizedDescription)) - \(self.hash)")
        if let listener = delegate {
            listener.websocketConnectionFailed(error: error)
        }
    }
    
    // Return true if websocket is connected to the URL of the specified printer
    func isConnected(printer: Printer) -> Bool {
        if let currentSocket = socket {
            return currentSocket.isConnected && serverURL == printer.hostname
        }
        return false
    }
    
    fileprivate func socketWrite(text: String) {
        if active {
            socket?.write(string: text)
        }
    }
    
    fileprivate func recreateSocket() {
        // Remove self as a delegate from old socket
        socket!.delegate = nil
        
        self.socket = WebSocket(request: self.socketRequest!)
        
        // Add as delegate of Websocket
        socket!.delegate = self
    }
    
    @objc func sendHeartbeat() {
        socketWrite(text: " ")
    }
}
