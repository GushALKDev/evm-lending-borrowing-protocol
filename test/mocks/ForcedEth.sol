// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev A contract with no receive or fallback: any ETH sent to it by a call reverts.
contract RejectingCaller {
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

/// @dev Sends its balance to `target` without calling it, the one way to push ETH past a contract's
///      receive logic.
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
