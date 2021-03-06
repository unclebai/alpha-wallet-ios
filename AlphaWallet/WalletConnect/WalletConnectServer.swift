//
//  WalletConnectSession.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 02.07.2020.
//

import UIKit
import WalletConnectSwift
import PromiseKit 

enum WalletConnectError: Error {
    case connectionInvalid
    case invalidWCURL
    case connect(WalletConnectURL)
    case request(WalletConnectServer.Request.AnyError)
}

protocol WalletConnectServerDelegate: class {
    func server(_ server: WalletConnectServer, shouldConnectFor connection: WalletConnectConnection, completion: @escaping (Bool) -> Void)
    func server(_ server: WalletConnectServer, action: WalletConnectServer.Action, request: WalletConnectRequest)
    func server(_ server: WalletConnectServer, didFail error: Error)
}

typealias WalletConnectRequest = WalletConnectSwift.Request

enum WalletConnectServerConnection {
    case connected(WalletConnectSession)
    case disconnected
}
typealias WalletConnectRequestID = WalletConnectSwift.RequestID

extension WalletConnectSession {
    var requester: DAppRequester {
        return .init(title: dAppInfo.peerMeta.name, url: dAppInfo.peerMeta.url)
    }
}

class WalletConnectServer {

    struct Configuration {
        let wallet: Wallet
        let rpcServer: RPCServer
    }

    private enum Keys {
        static let server = "AlphaWallet"
    }

    private let walletMeta = Session.ClientMeta(name: Keys.server, description: nil, icons: [], url: Config.gnosisURL)
    private lazy var server: Server = Server(delegate: self)

    private var configuration: Configuration
    private let config: Config
    var sessions: Subscribable<[WalletConnectSession]> = Subscribable([])
    var connection: Subscribable<WalletConnectServerConnection> = Subscribable(.disconnected)

    weak var delegate: WalletConnectServerDelegate?

    init(configuration: Configuration, config: Config) {
        self.configuration = configuration
        self.config = config

        sessions.value = server.openSessions()
        server.register(handler: self)
    }

    func set(configuration: Configuration) {
        self.configuration = configuration
    }

    func connect(url: WalletConnectURL) throws {
        try server.connect(to: url)
    }

    func reconnect(session: Session) throws {
        try server.reconnect(to: session)
    }

    func disconnect(session: Session) throws {

        try server.disconnect(from: session)
    }

    func fullfill(_ callback: Callback, request: WalletConnectSwift.Request) throws {
        let response = try Response(url: callback.url, value: callback.value.object, id: callback.id)

        server.send(response)
    }

    func reject(_ request: WalletConnectRequest) {
        server.send(.reject(request))
    }

    func hasConnected(session: Session) -> Bool {
        return server.openSessions().contains(where: {
            $0.dAppInfo.peerId == session.dAppInfo.peerId
        })
    }

    private func peerId(approved: Bool) -> String {
        return approved ? UUID().uuidString : String()
    }
}

extension WalletConnectServer: RequestHandler {

    func canHandle(request: WalletConnectSwift.Request) -> Bool {
        return true
    }

    func handle(request: WalletConnectSwift.Request) {
        DispatchQueue.main.async {
            guard let delegate = self.delegate, let id = request.id else { return }

            self.convert(request: request).map { type -> Action in
                return .init(id: id, url: request.url, type: type)
            }.done { action in
                delegate.server(self, action: action, request: request)
            }.catch { error in
                delegate.server(self, didFail: error)
            }
        }
    }

    private func convert(request: WalletConnectSwift.Request) -> Promise<Action.ActionType> {
        guard let connection = connection.value, case .connected(let session) = connection else {
            return .init(error: WalletConnectError.connectionInvalid)
        }

        let token = TokensDataStore.token(forServer: configuration.rpcServer)
        let transactionType: TransactionType = .dapp(token, session.requester)

        do {
            switch try Request(request: request) {
            case .sign(_, let message):
                return .value(.signMessage(message))
            case .signPersonalMessage(_, let message):

                return .value(.signPersonalMessage(message))
            case .signTransaction(let data):
                let data = UnconfirmedTransaction(transactionType: transactionType, bridge: data)

                return .value(.signTransaction(data))
            case .signTypedData(_, let data):

                return .value(.signTypedMessage(data))
            case .sendTransaction(let data):
                let data = UnconfirmedTransaction(transactionType: transactionType, bridge: data)

                return .value(.sendTransaction(data))
            case .sendRawTransaction(let rawValue):

                return .value(.sendRawTransaction(rawValue))
            case .unknown:

                return .value(.unknown)
            case .getTransactionCount(let filter):

                return .value(.getTransactionCount(filter))
            }
        } catch let error {
            return .init(error: error)
        }
    }
}

extension WalletConnectServer: ServerDelegate {

    func walletInfo(_ wallet: Wallet, approved: Bool) -> Session.WalletInfo {
        return Session.WalletInfo(
            approved: approved,
            accounts: [wallet.address.eip55String],
            chainId: configuration.rpcServer.chainID,
            peerId: peerId(approved: approved),
            peerMeta: walletMeta
        )
    }

    func server(_ server: Server, didFailToConnect url: WalletConnectURL) {
        DispatchQueue.main.async {
            guard var sessions = self.sessions.value, let delegate = self.delegate else { return }

            if let index = sessions.firstIndex(where: { $0.url.absoluteString == url.absoluteString }) {
                sessions.remove(at: index)
            }
            self.refresh(sessions: sessions)

            delegate.server(self, didFail: WalletConnectError.connect(url))
        }
    }

    private func refresh(sessions value: [Session]) {
        sessions.value = value
    }

    func server(_ server: Server, shouldStart session: Session, completion: @escaping (Session.WalletInfo) -> Void) {
        DispatchQueue.main.async {
            if let delegate = self.delegate {
                let connection = WalletConnectConnection(dAppInfo: session.dAppInfo, url: session.url.absoluteString)
                
                delegate.server(self, shouldConnectFor: connection) { [weak self] isApproved in
                    guard let strongSelf = self else { return }
                    print(session)
                    
                    if let chainIdToConnect = session.walletInfo?.chainId {
                        let rpcServer = RPCServer(chainID: chainIdToConnect)

                        guard strongSelf.config.enabledServers.contains(rpcServer) else { return }
                    }

                    let info = strongSelf.walletInfo(strongSelf.configuration.wallet, approved: isApproved)

                    completion(info)
                }
            } else {
                let info = self.walletInfo(self.configuration.wallet, approved: false)
                completion(info)
            }
        }
    }

    func server(_ server: Server, didConnect session: Session) {
        DispatchQueue.main.async {
            guard var sessions = self.sessions.value else { return }

            if let index = sessions.firstIndex(where: { $0.dAppInfo.peerId == session.dAppInfo.peerId }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }

            UserDefaults.standard.lastSession = session

            self.refresh(sessions: sessions)
            self.connection.value = .connected(session)
        }
    }

    func server(_ server: Server, didDisconnect session: Session) {
        DispatchQueue.main.async {
            guard var sessions = self.sessions.value else { return }

            if let index = sessions.firstIndex(where: { $0.dAppInfo.peerId == session.dAppInfo.peerId }) {
                sessions.remove(at: index)
            }

            UserDefaults.standard.lastSession = .none

            self.refresh(sessions: sessions)
            self.connection.value = .disconnected
        }
    }
}

struct WalletConnectConnection {
    let url: String
    let name: String
    let icon: URL?

    init(dAppInfo info: Session.DAppInfo, url: String) {
        self.url = url
        name = info.peerMeta.name
        icon = info.peerMeta.icons.first
    }
}
