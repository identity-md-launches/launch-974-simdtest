// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function getCode(string calldata artifact) external returns (bytes memory);
    function etch(address target, bytes calldata code) external;
    function roll(uint256 newHeight) external;
    function prank(address sender) external;
    function expectRevert() external;
    function expectRevert(bytes4 reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Test-only paired-token implementation, installed locally at the specified IMD address.
contract TestPairedToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    address public rejectedRecipient;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
        totalSupply += amount;
    }

    function rejectRecipient(address recipient) external {
        rejectedRecipient = recipient;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(recipient != rejectedRecipient, "recipient rejects transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}
