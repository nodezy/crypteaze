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

interface IOracle {
    function getTeazeUSDPrice() external view returns (uint256, uint256, uint256);
    function getbnbusdequivalent(uint256 amount) external view returns (uint256);
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
    function getTotalPacks() external view returns (uint);
    function getGenus(uint _packid) external view returns (string memory);
    function getAllGenus() external view returns (uint, string[] memory);
}

interface IDirectory {
    function getFarm() external view returns (address);
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
    function getInserter() external view returns (address);
    function getOracle() external view returns (address);
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
        uint8 makerNFTID;  
        uint8 takerNFTID; 
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
    
    uint minBet = 5;
    uint maxBet= 20;

    uint256 gameFee = 0.0025 ether;

    uint loserSBXamount = 200000000000;
  
    IDirectory public directory;
    address public DEAD = 0x000000000000000000000000000000000000dEaD;
    
    uint256 private randNonce;
    uint256 timeEnding = 1296000; //default game lifetime of 15 days.
    
     
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

        uint usdamount = getOracleAmounts(msg.value);
        require(usdamount >= minBet && usdamount <= maxBet, "E90");

        randNonce++;

        _GameIds.increment();

        uint256 gameid = _GameIds.current();

        GameInfo storage gameinfo = gameInfo[gameid];

        (uint nftid, uint packid,, uint mintClass,) = getPVPNFTinfo(_tokenid);

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, 100); //get user roll 0-99
        uint256 vulnerabilityroll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, 15); //get vulnerability roll 0-14

        gameinfo.makerAddress = _msgSender();
        gameinfo.makerBNBamount = uint128(msg.value);
        gameinfo.makerNFTPack = uint8(packid);
        gameinfo.makerNFTID = uint8(nftid);
        gameinfo.makerRoll = uint64(roll++);
        gameinfo.makerRollDelta = uint64(vulnerabilityroll++); //get random roll between 1-15 
        gameinfo.makerTokenID = uint16(_tokenid);
        gameinfo.makerNFTratio = uint64(mintClass);
        gameinfo.makerVulnerable = uint8(getVulnerability(packid)); 
        gameinfo.timeStart = uint64(block.timestamp);
        gameinfo.timeEnds = uint64(block.timestamp.add(timeEnding));

        IERC721(directory.getNFT()).safeTransferFrom(_msgSender(), address(this), _tokenid);

        gameinfo.open = true;
    }

    function getVulnerability(uint _packid) internal returns (uint) {

        uint packs = ITeazePacks(directory.getPacks()).getTotalPacks();

        uint256 genusroll = Inserter(directory.getInserter()).getRandMod(randNonce, _packid, packs); //get random pack

        genusroll++; //Normalize cause there's no zero pack

        if(_packid == genusroll) {

            randNonce++;

            getVulnerability(_packid);

        } else {

            return genusroll;
        }

        return 0;

    }

    function viewPVP(uint _gameId) external view returns (
        address makerAddress, 
        address takerAddress,  
        uint16 makerTokenID, 
        uint16 takerTokenID, 
        uint8 makerNFTPack,  
        uint8 takerNFTPack,  
        uint8 makerNFTID,  
        uint8 takerNFTID, 
        uint8 makerVulnerable,  
        uint8 takerVulnerable, 
        uint64 timeStart,
        uint64 timeEnds,
        uint64 makerRoll,
        uint64 takerRoll,
        uint64 makerRollDelta,
        uint64 takerRollDelta,
        uint64 makerNFTratio,
        uint128 makerBNBamount,
        uint128 takerBNBamount,
        string memory winner,
        bool open
    ) {

        GameInfo storage gameinfo = gameInfo[_gameId];

        if (gameinfo.open) {
            require(gameinfo.makerAddress == _msgSender(), "E90");
        }

        return (
            makerAddress, 
            takerAddress,  
            makerTokenID, 
            takerTokenID, 
            makerNFTPack,  
            takerNFTPack,  
            makerNFTID,  
            takerNFTID, 
            makerVulnerable,  
            takerVulnerable, 
            timeStart,
            timeEnds,
            makerRoll,
            takerRoll,
            makerRollDelta,
            takerRollDelta,
            makerNFTratio,
            makerBNBamount,
            takerBNBamount,
            winner,
            open
        );

    }

    function viewGame(uint _gameId) external view returns (
        address makerAddress, 
        uint16 makerTokenID, 
        uint8 makerNFTPack,  
        uint8 makerNFTID,  
        uint64 timeStart,
        uint64 timeEnds,
        uint64 makerNFTratio,
        uint128 makerBNBamount,
        bool open
    ) {

        GameInfo storage gameinfo = gameInfo[_gameId];

        if (!gameinfo.open) {
            revert("E91");
        }

        return (
            makerAddress, 
            makerTokenID, 
            makerNFTPack,  
            makerNFTID,    
            timeStart,
            timeEnds,
            makerNFTratio,
            makerBNBamount,
            open
        );

    }

    function getNFTdelta(uint _mintClass, uint _gameId) external view returns (uint amount) {

        GameInfo storage gameinfo = gameInfo[_gameId];

        if(gameinfo.makerNFTratio == _mintClass) {
            return gameinfo.makerBNBamount;
        }

        if(gameinfo.makerNFTratio > _mintClass) {
           return uint(gameinfo.makerNFTratio).sub(_mintClass).mul(gameinfo.makerBNBamount);
        }

        if(gameinfo.makerNFTratio < _mintClass) {
           return uint(_mintClass).sub(gameinfo.makerNFTratio).mul(gameinfo.makerBNBamount);
        }

    }

    function getOracleAmounts(uint _bnbamount) public view returns (uint amountusd) {
        uint usdamount = IOracle(directory.getOracle()).getbnbusdequivalent(_bnbamount);
        return usdamount;
    }


    //function acceptPVP

    function getPVPNFTinfo(uint _tokenID) public view returns (uint, uint, uint, uint, string memory) {

        address packs = directory.getPacks();

        uint nftid = ITeazePacks(packs).getNFTIDwithToken(_tokenID);
        uint packid = ITeazePacks(packs).getPackIDbyNFT(nftid);
        uint mintPercent = ITeazePacks(packs).getNFTPercent(nftid);
        uint mintClass = ITeazePacks(packs).getNFTClass(nftid);

        string memory genus = ITeazePacks(packs).getGenus(packid);

        return(nftid, packid, mintPercent, mintClass, genus);
    }

    function delistPVP(uint _gameId) external nonReentrant {
        GameInfo storage gameinfo = gameInfo[_gameId];

        if (gameinfo.open) {
            require(gameinfo.makerAddress == _msgSender(), "E90");
        } else {
            return;
        }

        require(block.timestamp >= gameinfo.timeEnds, "E96");

        gameinfo.open = false;
        gameinfo.winner = "Expired";

        payable(_msgSender()).transfer(uint(gameinfo.makerBNBamount).sub(gameFee));
        IERC721(directory.getNFT()).safeTransferFrom(address(this), _msgSender(), gameinfo.makerTokenID);
        
    }

    function changeMinMaxBet(uint _min, uint _max) external onlyAuthorized {
        require(_min < _max, "E92");
        require(_min > 0, "E93");

        minBet = _min;
        maxBet = _max;
    }

    function changeTimeEnding(uint _timeEnd) external onlyAuthorized {
        require(_timeEnd > 86400, "E94");

        timeEnding = _timeEnd;
    }

    function changeGameFee(uint _feeAmount) external onlyAuthorized {
        gameFee = _feeAmount;
    }

    function changeRunnerUpAmount(uint _SBXamount) external onlyAuthorized {
        loserSBXamount = _SBXamount;
    }
}
