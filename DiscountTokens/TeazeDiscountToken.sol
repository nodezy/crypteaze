// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
 
// Allows another user(s) to change contract variables
contract Authorizable is Ownable {

    mapping(address => bool) public authorized;

    modifier onlyAuthorized() {
        require(authorized[_msgSender()] || owner() == address(_msgSender()), "Caller is not owner or authorized");
        _;
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0));
        authorized[_toAdd] = true;
        
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != address(0));
        require(_toRemove != address(_msgSender()));
        authorized[_toRemove] = false;
    }

}

/**
 * @title  
 * @dev Very simple ERC20 Token example, where all tokens are pre-assigned to the creator.
 * Note they can later distribute these tokens as they wish using `transfer` and other
 * `ERC20` functions.
 * Based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.5.1/contracts/examples/SimpleToken.sol
 */
contract TeazeDiscountToken is ERC20, Authorizable {
    /**
     * @dev Constructor that gives msg.sender all of existing tokens.
     */
    constructor(
        /*string memory name,
        string memory symbol,
        uint256 initialSupply*/
    ) ERC20("TeazeDiscountToken", "TDT1.5%") {
        authorized[owner()] = true;
        _mint(msg.sender, 1000000000000000000000);
    }

    receive() external payable {}

    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyOwner {
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

     function transfer(address recipient, uint256 amount) public override returns (bool) {
       if(validateTransfer(msg.sender, recipient)) {
          _transfer(msg.sender, recipient, amount);  
          return true;      
        } else {
          return false;
        }
        
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if(validateTransfer(sender, recipient)) {
          _transfer(sender, recipient, amount);  
          return true;      
        } else {
          return false;
        }
    }

    function validateTransfer(address _sender, address _recipient) internal view returns (bool) {
        if(authorized[_sender] || _recipient == address(0x000000000000000000000000000000000000dEaD)) {
            return true;
        } else {
            return false;
        }
        
    }

}
