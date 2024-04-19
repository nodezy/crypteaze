// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
    function getNFTIDwithToken(uint256 _tokenid) external view returns (uint256);
}

interface IOracle {
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
    function getCrates() external view returns (address);
}

interface ISimpCrates {
    function claimedNFT(uint token) external view returns (bool);
}

contract TeazePVP is Ownable, Authorizable, Whitelisted, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter public _GameIds;
    Counters.Counter public _openGames;  
    Counters.Counter public _closedGames;  
    Counters.Counter public _expiredGames; 

    struct GameInfo { 
        address makerAddress; 
        uint16 makerTokenID; 
        uint8 makerNFTPack;  
        uint8 makerNFTID;  
        uint8 makerVulnerable;
        uint8 makerNFTratio;
        uint64 makerRoll;
        uint64 makerRollDelta;
        uint64 timeStart;
        uint64 timeEnds;
        uint128 makerBNBamount;
        bool open; 
    }

    struct GameResult {
        address takerAddress;  
        uint16 takerTokenID; 
        uint8 takerNFTPack;  
        uint8 takerVulnerable; 
        uint8 takerMintClass;
        uint8 takerNFTID; 
        uint64 timeEnds;
        uint64 takerRoll;
        uint64 takerRollDelta;
        uint64 runnerUpAmount;
        uint128 takerBNBamount;
        string winner;
    }

    mapping(uint256 => GameInfo) private gameInfo; 
    mapping(uint256 => GameResult) private gameResult; 
    mapping(address => uint) public userGames; //userGames[address];
    mapping(address => mapping(uint => uint)) public userGameIDs; //userGameIDs[address][x][gameID];

    uint256[] private opengamearray;  
    uint256[] private closedgamearray;  
    uint256[] private expiredgamearray;  
 
    uint minBet = 5;
    uint maxBet= 50;

    uint256 gameFee = 0.0025 ether;

    uint vulnMod = 15; //range 0-14 of rando vulnerability
    uint rollMod = 70; 
    uint rollNormalizer = 31;

    uint makerNFTnumerator = 65;
    uint takerNFTnumerator = 150;

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

    function openPVP(uint _tokenid) public payable nonReentrant {

        require(ITeazeFarm(directory.getFarm()).getUserStaked(_msgSender()), "E35");
        require(!ISimpCrates(directory.getCrates()).claimedNFT(_tokenid), "E97");
        
        require(msg.value >= getOracleAmounts(minBet) && msg.value <= getOracleAmounts(maxBet), "E89");

        randNonce++;

        _GameIds.increment();

        uint256 gameid = _GameIds.current();

        GameInfo storage gameinfo = gameInfo[gameid];

        (uint nftid, uint packid,, uint mintClass,) = getPVPNFTinfo(_tokenid);

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, rollMod); //get user roll 0-59
        uint256 vulnerabilityroll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, vulnMod); //get vulnerability roll 0-14

        gameinfo.makerAddress = _msgSender();
        gameinfo.makerBNBamount = uint128(msg.value);
        gameinfo.makerNFTPack = uint8(packid);
        gameinfo.makerNFTID = uint8(nftid);
        gameinfo.makerRoll = uint64(roll.add(rollNormalizer));
        gameinfo.makerRollDelta = uint64(vulnerabilityroll++);  
        gameinfo.makerTokenID = uint16(_tokenid);
        gameinfo.makerNFTratio = uint8(mintClass);
        gameinfo.makerVulnerable = uint8(getVulnerability(packid)); 
        gameinfo.timeStart = uint64(block.timestamp);
        gameinfo.timeEnds = uint64(block.timestamp.add(timeEnding));

        IERC721(directory.getNFT()).safeTransferFrom(_msgSender(), address(this), _tokenid);

        gameinfo.open = true;

        userGames[_msgSender()]++;

        uint usergames = userGames[_msgSender()];

        userGameIDs[_msgSender()][usergames]= gameid;

        opengamearray.push(gameid);
    }

    function acceptPVP(uint _tokenid, uint _gameid) external payable nonReentrant {

        require(ITeazeFarm(directory.getFarm()).getUserStaked(_msgSender()), "E35");
        require(!ISimpCrates(directory.getCrates()).claimedNFT(_tokenid), "E97");
        
        GameInfo storage gameinfo = gameInfo[_gameid];
        GameResult storage gameresult = gameResult[_gameid];

        (uint nftid, uint packid,, uint mintClass,) = getPVPNFTinfo(_tokenid);

        require(msg.value >= getNFTdelta(mintClass, _gameid), "E89");
        require(_msgSender() != gameinfo.makerAddress, "102");

        randNonce++;

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, rollMod); //get user roll 0-59
        uint256 vulnerabilityroll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, vulnMod); //get vulnerability roll 0-14

        gameresult.takerAddress = _msgSender();
        gameresult.takerBNBamount = uint128(msg.value);
        gameresult.takerNFTPack = uint8(packid);
        gameresult.takerNFTID = uint8(nftid);
        gameresult.takerRoll = uint64(roll.add(rollNormalizer));
        gameresult.takerRollDelta = uint64(vulnerabilityroll++);  
        gameresult.takerTokenID = uint16(_tokenid);
        gameresult.takerMintClass = uint8(mintClass);
        gameresult.takerVulnerable = uint8(getVulnerability(packid)); 

        uint makerTempRoll;
        uint takerTempRoll;

        if(gameinfo.makerNFTPack == gameresult.takerVulnerable) {
            takerTempRoll = uint(gameresult.takerRoll).sub(gameresult.takerRollDelta);
        } else {
            takerTempRoll = gameresult.takerRoll;
        }

        if(gameresult.takerNFTPack == gameinfo.makerVulnerable) {
            makerTempRoll = uint(gameinfo.makerRoll).sub(gameinfo.makerRollDelta);
        } else {
            makerTempRoll = gameinfo.makerRoll;
        }

        if(makerTempRoll == takerTempRoll) { //tie

            gameresult.winner = "Tie";

            payable(gameinfo.makerAddress).transfer(uint(gameinfo.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gameinfo.makerAddress, gameinfo.makerTokenID);

            payable(gameresult.takerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));

        } 
        
        if(makerTempRoll > takerTempRoll) { //maker wins

            gameresult.winner = "Maker";
            gameresult.runnerUpAmount = uint64(loserSBXamount.mul(gameresult.takerMintClass));
            ITeazeFarm(directory.getFarm()).increaseSBXBalance(_msgSender(), gameresult.runnerUpAmount);

            payable(gameinfo.makerAddress).transfer(uint(gameinfo.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gameinfo.makerAddress, gameinfo.makerTokenID);

            payable(gameinfo.makerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(gameresult.takerAddress, gameinfo.makerAddress, gameresult.takerTokenID);

        } 

        if(makerTempRoll < takerTempRoll) { //taker wins

            gameresult.winner = "Taker";
            gameresult.runnerUpAmount = uint64(loserSBXamount.mul(gameinfo.makerNFTratio));
            ITeazeFarm(directory.getFarm()).increaseSBXBalance(gameinfo.makerAddress, gameresult.runnerUpAmount);

            payable(gameresult.takerAddress).transfer(uint(gameinfo.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gameresult.takerAddress, gameinfo.makerTokenID);

            payable(gameresult.takerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));

        } 

        userGames[_msgSender()]++;

        uint usergames = userGames[_msgSender()];

        userGameIDs[_msgSender()][usergames]= _gameid;

        gameinfo.open = false;
        closeGame(_gameid, true);
        
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

    function viewGameInfo(uint _gameId) external view returns (
        address makerAddress, 
        uint16 makerTokenID, 
        uint8 makerNFTPack,  
        uint8 makerNFTID,  
        uint8 makerVulnerable,
        uint64 makerRoll,
        uint64 makerRollDelta,
        uint64 timeStart,
        uint64 makerNFTratio,
        uint128 makerBNBamount,
        bool open
    ) {

        GameInfo storage gameinfo = gameInfo[_gameId];

        if (authorized[_msgSender()] || gameinfo.makerAddress == _msgSender()) {

            return (
                gameinfo.makerAddress, 
                gameinfo.makerTokenID, 
                gameinfo.makerNFTPack,  
                gameinfo.makerNFTID,  
                gameinfo.makerVulnerable,
                gameinfo.makerRoll,
                gameinfo.makerRollDelta,
                gameinfo.timeStart,
                gameinfo.makerNFTratio,
                gameinfo.makerBNBamount,
                gameinfo.open
            );

        } else {

            return (
                gameinfo.makerAddress, 
                gameinfo.makerTokenID, 
                gameinfo.makerNFTPack,  
                gameinfo.makerNFTID,  
                0,
                0,
                0,
                gameinfo.timeStart,
                gameinfo.makerNFTratio,
                gameinfo.makerBNBamount,
                gameinfo.open
            );

        }     

    }

    function viewGameResult(uint _gameId) external view returns (
        address takerAddress,  
        uint16 takerTokenID, 
        uint8 takerNFTPack,  
        uint8 takerVulnerable, 
        uint8 takerNFTID, 
        uint64 timeEnds,
        uint64 takerRoll,
        uint64 takerRollDelta,
        uint64 runnerUpAmount,
        uint128 takerBNBamount,
        string memory winner
    ) {

        GameResult storage gameresult = gameResult[_gameId];

        return (
            gameresult.takerAddress,  
            gameresult.takerTokenID, 
            gameresult.takerNFTPack,  
            gameresult.takerVulnerable, 
            gameresult.takerNFTID, 
            gameresult.timeEnds,
            gameresult.takerRoll,
            gameresult.takerRollDelta,
            gameresult.runnerUpAmount,
            gameresult.takerBNBamount,
            gameresult.winner
        );

    }

    function getNFTdelta(uint _mintClass, uint _gameId) public view returns (uint amount) {

        GameInfo storage gameinfo = gameInfo[_gameId];

        if(gameinfo.makerNFTratio == _mintClass) {
            return gameinfo.makerBNBamount;
        }

        if(gameinfo.makerNFTratio > _mintClass) { //maker NFT higher rarity
           return uint(gameinfo.makerBNBamount).mul(uint(gameinfo.makerNFTratio).sub(_mintClass--)).mul(makerNFTnumerator).div(100);
        }

        if(gameinfo.makerNFTratio < _mintClass) { //maker NFT lower rarity
            return uint(uint(gameinfo.makerBNBamount).mul(100).div(uint((_mintClass++).sub(gameinfo.makerNFTratio)).mul(100))).mul(takerNFTnumerator).div(100);
        }

    }

    function getOracleAmounts(uint _usdamount) public view returns (uint amountusd) {
        uint bnbamount = IOracle(directory.getOracle()).getbnbusdequivalent(_usdamount);
        return bnbamount;
    }

    function getPVPNFTinfo(uint _tokenID) public view returns (uint, uint, uint, uint, string memory) {

        address packs = directory.getPacks();

        uint nftid = ITeazeNFT(directory.getNFT()).getNFTIDwithToken(_tokenID);
        uint packid = ITeazePacks(packs).getPackIDbyNFT(nftid);
        uint mintPercent = ITeazePacks(packs).getNFTPercent(nftid);
        uint mintClass = ITeazePacks(packs).getNFTClass(nftid);

        string memory genus = ITeazePacks(packs).getGenus(packid);

        return(nftid, packid, mintPercent, mintClass, genus);
    }

    function delistPVP(uint _gameId) external nonReentrant {
        GameInfo storage gameinfo = gameInfo[_gameId];
        GameResult storage gameresult = gameResult[_gameId];

        if (gameinfo.open) {
            require(gameinfo.makerAddress == _msgSender(), "E90");
        } else {
            return;
        }

        require(block.timestamp >= gameinfo.timeEnds, "E96");

        gameinfo.open = false;
        gameresult.winner = "Expired";

        payable(_msgSender()).transfer(uint(gameinfo.makerBNBamount).sub(gameFee));
        IERC721(directory.getNFT()).safeTransferFrom(address(this), _msgSender(), gameinfo.makerTokenID);

        closeGame(_gameId, false);
        
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

    function getAllUserGames(address _user) public view returns (uint, uint[] memory) {

        uint games = userGames[_user];

        uint[] memory gameids = new uint[](games);

        for(uint x=1;x<=games;x++) {

            gameids[x] = userGameIDs[_user][x];

        }

        return(games, gameids);
    }

    function getUserOpenGames(address _user) external view returns (uint[] memory) {

        (uint games, uint[] memory gameids) = getAllUserGames(_user);

        uint[] memory opengameids = new uint[](games);

        uint count;

        for(uint x=1;x<=games;x++) {

            GameInfo storage gameinfo = gameInfo[gameids[x]];

            if(gameinfo.open) {

                opengameids[count] = userGameIDs[_user][x];

                count++;

            }

        }

        return opengameids;

    }

    function getUserClosedGames(address _user) external view returns (uint[] memory) {

        (uint games, uint[] memory gameids) = getAllUserGames(_user);

        uint[] memory closedgameids = new uint[](games);

        uint count;

        for(uint x=1;x<=games;x++) {

            GameInfo storage gameinfo = gameInfo[gameids[x]];

            if(!gameinfo.open) {

                closedgameids[count] = userGameIDs[_user][x];

                count++;

            }

        }

        return closedgameids;

    }

    function closeGame(uint256 _gameId, bool status) internal { //change to internal for production
        uint arraylength = opengamearray.length;

        //Remove open game from active array
        for(uint x = 0; x < arraylength; x++) {
            if (opengamearray[x] == _gameId) {
                opengamearray[x] = opengamearray[arraylength-1];
                opengamearray.pop();

                if(_openGames.current() > 0) {
                    _openGames.decrement();
                }

                //Add open game to closed (true) or expired (false) array

                if (status) {
 
                    closedgamearray.push(_gameId);

                    _closedGames.increment();

                } else {

                    expiredgamearray.push(_gameId);

                    _expiredGames.increment();

                }
              
                return;
            }
        }       

    }

    function viewopenGames() external view returns (uint256[] memory lootboxes){

        return opengamearray;

    }

    function viewClosedGames(uint _startingpoint, uint _length) external view returns (uint256[] memory) {

        uint256[] memory array = new uint256[](_length); 

        //Loop through the segment at the starting point
        for(uint x = 0; x < _length; x++) {
          array[x] = closedgamearray[_startingpoint.add(x)];
        }   

        return array;
    }

    function viewExpiredGames(uint _startingpoint, uint _length) external view returns (uint256[] memory) {

        uint256[] memory array = new uint256[](_length); 

        //Loop through the segment at the starting point
        for(uint x = 0; x < _length; x++) {
          array[x] = expiredgamearray[_startingpoint.add(x)];
        }   

        return array;
    }

    function changeVulnMod(uint _vulnMod) external onlyAuthorized {
        require(vulnMod >=5, "E96");
        require(vulnMod < rollNormalizer, "E97");
        vulnMod = _vulnMod;
    }

    function changeRollParams(uint _rollMod, uint _rollNormalizer) external onlyAuthorized {
        require(_rollMod >= 50, "E98");
        require(_rollMod > rollNormalizer, "E99");
        require(_rollNormalizer > vulnMod, "E100");

        rollMod = _rollMod;
        rollNormalizer = _rollNormalizer;
    }

    function changeNumerators(uint _maker, uint _taker) external onlyAuthorized {
        require(_maker < _taker, "E101");
        makerNFTnumerator = _maker;
        takerNFTnumerator = _taker;
    }

    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyOwner {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }
}
