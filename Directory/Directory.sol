// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 
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

contract Directory is Ownable, Authorizable {

    address public getNFTMarketing; 
    address public getDiscount1;
    address public getDiscount2;
    address public getDiscount3;
    address public getTeazeToken;
    address public getOracle;
    address public getPair;
    address public getFarm;
    address public getSBX;
    address public getLotto;
    address public getInserter;
    address public getNFT;
    address public getPacks;
    address public getCrates;
    address public getMarketplace;
    address public getPVP;

    constructor() {}

    receive() external payable {}

    function updateOne(
        address a1,
        address a2,
        address a3,
        address a4,
        address a5,
        address a6,
        address a7,
        address a8
    ) 
    external onlyAuthorized {
        getNFTMarketing = a1; 
        getDiscount1 = a2;
        getDiscount2 = a3;
        getDiscount3 = a4;
        getTeazeToken = a5;
        getOracle = a6;
        getPair = a7;
        getFarm = a8;
    }

    function updateTwo(
        address a9,
        address a10,
        address a11,
        address a12,
        address a13,
        address a14,
        address a15,
        address a16
    ) 
    external onlyAuthorized {
        getSBX = a9;
        getLotto = a10;
        getInserter = a11;
        getNFT = a12;
        getPacks = a13;
        getCrates = a14;
        getMarketplace = a15;
        getPVP = a16;
    }

    function rescueETHFromContract() external onlyAuthorized {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) external onlyAuthorized {
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

}
