// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./auth.sol";

interface ITeazeFarm {
    function getUserStaked(address _holder) external view returns (bool);
    function increaseSBXBalance(address _address, uint256 _amount) external;
}

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function mint(address _recipient, string memory _uri, uint _packNFTid) external returns (uint256,bool); 
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function setApprovalForAll(address operator, bool status) external;
}

interface Inserter {
    function makeActive() external; 
    function getNonce() external view returns (uint256);
    function getRandMod(uint256 _extNonce, uint256 _modifier, uint256 _modulous) external view returns (uint256);
}

interface ITeazePacks {
    function getPackIDbyNFT(uint256 _nftid) external view returns (uint256); 
    function getCurrentNFTID() external view returns (uint256);
    function getNFTURI(uint256 _nftid) external view returns (string memory);
    function getPackInfo(uint256 _packid) external view returns (uint256,uint256,uint256,uint256,bool,bool);   
    function getNFTClass(uint256 _nftid) external view returns (uint256);
    function getNFTPercent(uint256 _nftid) external view returns (uint256);
    function getLootboxAble(uint256 _nftid) external view returns (bool); 
    function getPackTimelimitCrates(uint256 _nftid) external view returns (bool);
    function getNFTExists(uint256 _nftid) external view returns (bool);
    function getNFTIDwithToken(uint256 _tokenid) external view returns (uint256);
}

interface IDirectory {
    function getFarm() external view returns (address);
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
    function getInserter() external view returns (address);
    
}

contract TeazePacks is Ownable, Authorizable, Whitelisted, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter public _GameIds;

    struct GameInfo { 
        address makerAddress; 
        address takerAddress;  
        uint16 makerTokenID; 
        uint16 takerTokenID; 
        uint8 makerNFTPack;  
        uint8 takerNFTPack;  
        uint8 makerNFTrarity;  
        uint8 takerNFTrarity; 
        uint8 makerVulnerable;  
        uint8 takerVulnerable; 
        uint64 timeStart;
        uint64 timeEnds;
        uint64 makerRoll;
        uint64 takerRoll;
        uint64 makerRollDelta;
        uint64 takerRollDelta;
        uint64 makerNFTratio;
        uint128 makerBNBamount;
        uint128 takerBNBamount;
        string winner;
        bool open; 
    }

    struct GenusInfo {
        uint8 packID;
        string genusName;
    }

    mapping(uint256 => GameInfo) private gameInfo; 
    mapping(uint256=> GenusInfo) public genusInfo;

    uint NFTdelta;
    uint minBet = 1;
    uint maxBet= 100;
  
    IDirectory public directory;
    address public DEAD = 0x000000000000000000000000000000000000dEaD;
    
    uint256 private randNonce;
    uint256 timeEnding = 1296000; //default bet lifetime of 15 days.
    
     
    constructor(address _directory) {
        directory = IDirectory(_directory);
        authorized[owner()] = true;
        randNonce = Inserter(directory.getInserter()).getNonce();
        Inserter(directory.getInserter()).makeActive();
        addWhitelisted(owner());
    }

    receive() external payable {}


    function openPVP(uint _tokenid, uint _betamount) public payable nonReentrant {
        require(_betamount == msg.value, "E89");
        require(msg.value >= minBet && msg.value <= maxBet, "E90");

        randNonce++;

        _GameIds.increment();

        uint256 gameid = _GameIds.current();

        GameInfo storage gameinfo = gameInfo[gameid];

        address packs = directory.getPacks();

        uint nftid = ITeazePacks(packs).getNFTIDwithToken(_tokenid);

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, 100); //get user roll 0-99
        uint256 vulnerabilityroll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, 15); //get vulnerability roll 0-14

        gameinfo.makerAddress = _msgSender();
        gameinfo.makerBNBamount = uint128(msg.value);
        gameinfo.makerNFTPack = uint8(ITeazePacks(packs).getPackIDbyNFT(nftid));
        gameinfo.makerNFTrarity = uint8(ITeazePacks(packs).getNFTPercent(nftid));
        gameinfo.makerRoll = uint64(roll++);
        gameinfo.makerRollDelta = uint64(vulnerabilityroll++); //get random roll between 1-15 
        gameinfo.makerTokenID = uint16(_tokenid);
        gameinfo.makerNFTratio = 0; 
        gameinfo.makerVulnerable = 0; //write view function to return a random vulnerability
        gameinfo.timeStart = uint64(block.timestamp);
        gameinfo.timeEnds = uint64(block.timestamp.add(timeEnding));

        IERC721(directory.getNFT()).safeTransferFrom(_msgSender(), address(this), _tokenid);

        gameinfo.open = true;
    }

    //function acceptPVP

    //function getNFTdelta

    //function getNFTinfo

    //function closePVP

    //function getAllGenus

    //functio getVulnerability

    //function changeMinMaxBet

    //function changeTimeEnding
}
