// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import RealmSwift

class MigrationInitializer: Initializer {
    private let account: Wallet

    lazy var config: Realm.Configuration = {
        return RealmConfiguration.configuration(for: account)
    }()

    init(account: Wallet) {
        self.account = account
    }

    func perform() {
        config.schemaVersion = 7
        //NOTE: use [weak self] to avaid memory leak
        config.migrationBlock = { [weak self] migration, oldSchemaVersion in
            guard let strongSelf = self else { return }

            if oldSchemaVersion < 2 {
                //Fix bug created during multi-chain implementation. Where TokenObject instances are created from transfer Transaction instances, with the primaryKey as a empty string; so instead of updating an existing TokenObject, a duplicate TokenObject instead was created but with primaryKey empty
                migration.enumerateObjects(ofType: TokenObject.className()) { oldObject, newObject in
                    guard oldObject != nil else { return }
                    guard let newObject = newObject else { return }
                    if let primaryKey = newObject["primaryKey"] as? String, primaryKey.isEmpty {
                        migration.delete(newObject)
                        return
                    }
                }
            }
            if oldSchemaVersion < 3 {
                migration.enumerateObjects(ofType: Transaction.className()) { oldObject, newObject in
                    guard oldObject != nil else { return }
                    guard let newObject = newObject else { return }
                    newObject["isERC20Interaction"] = false
                }
            }
            if oldSchemaVersion < 4 {
                migration.enumerateObjects(ofType: TokenObject.className()) { oldObject, newObject in
                    guard let oldObject = oldObject else { return }
                    guard let newObject = newObject else { return }
                    //Fix bug introduced when OpenSea suddenly includes the DAI stablecoin token in their results with an existing versioned API endpoint, and we wrongly tagged it as ERC721, possibly crashing when we fetch the balance (casting a very large ERC20 balance with 18 decimals to an Int)
                    guard let contract = oldObject["contract"] as? String, contract == "0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359" else { return }
                    newObject["rawType"] = "ERC20"
                }
            }
            if oldSchemaVersion < 5 {
                migration.enumerateObjects(ofType: TokenObject.className()) { oldObject, newObject in
                    guard let oldObject = oldObject else { return }
                    guard let newObject = newObject else { return }
                    //Fix bug introduced when OpenSea suddenly includes the DAI stablecoin token in their results with an existing versioned API endpoint, and we wrongly tagged it as ERC721 with decimals=0. The earlier migration (version=4) only set the type back to ERC20, but the decimals remained as 0
                    guard let contract = oldObject["contract"] as? String, contract == "0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359" else { return }
                    newObject["decimals"] = 18
                }
            }
            if oldSchemaVersion < 6 {
                migration.enumerateObjects(ofType: TokenObject.className()) { oldObject, newObject in
                    guard oldObject != nil else { return }
                    guard let newObject = newObject else { return }

                    newObject["shouldDisplay"] = true
                    newObject["sortIndex"] = RealmOptional<Int>(nil)
                }
            }
            if oldSchemaVersion < 7 {
                //Fix bug where we marked all transactions as completed successfully without checking `isError` from Etherscan
                migration.deleteData(forType: Transaction.className())
                for each in RPCServer.allCases {
                    Config.setLastFetchedErc20InteractionBlockNumber(0, server: each, wallet: strongSelf.account.address)
                }
                migration.deleteData(forType: EventActivity.className())
            }
        }
    }
}
