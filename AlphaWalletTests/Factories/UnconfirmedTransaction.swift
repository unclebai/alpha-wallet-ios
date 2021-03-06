// Copyright SIX DAY LLC. All rights reserved.

import Foundation
@testable import AlphaWallet
import BigInt

extension UnconfirmedTransaction {
    static func make(
        transactionType: TransactionType = .nativeCryptocurrency(TokenObject(), destination: .none, amount: nil),
        value: BigInt = BigInt(1),
        to: AlphaWallet.Address = .make(),
        data: Data = Data(),
        gasLimit: BigInt? = BigInt(100000),
        gasPrice: BigInt? = BigInt(1000),
        nonce: BigInt? = BigInt(1)
    ) -> UnconfirmedTransaction {
        return UnconfirmedTransaction(
            transactionType: transactionType,
            value: value,
            recipient: to,
            data: data,
            tokenId: nil,
            gasLimit: gasLimit,
            gasPrice: gasPrice,
            nonce: nonce
        )
    }
}
