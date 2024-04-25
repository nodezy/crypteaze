// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./auth.sol";

interface ITeazeFarm {
    function getUserStaked(address _holder) external view returns (bool);
    function increaseSBXBalance(address _address, uint256 _amount) external;
}

interface ITeazeNFT {
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
    function getNFTClass(uint256 _nftid) external view returns (uint256);
    function getNFTPercent(uint256 _nftid) external view returns (uint256);
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
    function getLotto() external view returns (address);
    function getCrates() external view returns (address);
}

interface ISimpCrates {
    function claimedNFT(uint token) external view returns (bool);
}

contract TeazePVP is Ownable, Authorizable, Whitelisted, IERC721Receiver, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter public _GameIds;
    Counters.Counter public _openGames;  
    Counters.Counter public _closedGames;  
    Counters.Counter public _expiredGames; 

    struct GameMaker { 
        address makerAddress; 
        uint16 makerTokenID; 
        uint8 makerNFTPack;  
        uint8 makerNFTID;  
        uint8 makerStrong;
        uint8 makerStrongRoll;
        uint8 makerWeak;
        uint8 makerWeakRoll;
        uint8 makerRoll;
        uint8 makerNFTratio;
        uint128 makerBNBamount;
        string makerGenus;
        bool open; 
    }

    struct GameTaker {
        address takerAddress;  
        uint16 takerTokenID; 
        uint8 takerNFTPack;  
        uint8 takerNFTID; 
        uint8 takerStrong;
        uint8 takerStrongRoll;
        uint8 takerWeak;
        uint8 takerWeakRoll;
        uint8 takerMintClass;
        uint8 takerRoll;
        uint64 runnerUpAmount;
        uint128 takerBNBamount;
        string takerGenus;
        string winner;
    }

    struct TimeStamps {
        uint64 timeStart;
        uint64 timeExpires;
        uint64 timeEnds;

    }

    mapping(uint256 => GameMaker) private gameMaker; 
    mapping(uint256 => GameTaker) public gameTaker; 
    mapping(uint256 => TimeStamps) public timeStamps; 
    mapping(address => uint) public userGames; //userGames[address];
    mapping(address => mapping(uint => uint)) public userGameIDs; //userGameIDs[address][x][gameID];

    uint256[] private opengamearray;  
    uint256[] private closedgamearray;  
    uint256[] private expiredgamearray;  
 
    uint minBet = 5;
    uint maxBet= 300;

    uint gameFee = 0.0045 ether;
    uint totalFees;
    uint strenMod = 25; //range 0-24 of rando strength
    uint weakMod = 15; //range 0-14 of rando weakness
    uint rollMod = 70; 
    uint rollNormalizer = 31;

    uint makerNFTnumerator = 65;
    uint takerNFTnumerator = 150;

    uint loserSBXamount = 200000000000;
  
    IDirectory public directory;
    //address public DEAD = 0x000000000000000000000000000000000000dEaD;
    
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

    
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function openPVP(uint _tokenid) public payable nonReentrant {

        require(ITeazeFarm(directory.getFarm()).getUserStaked(_msgSender()), "E35");
        require(!ISimpCrates(directory.getCrates()).claimedNFT(_tokenid), "E97");
        
        require(msg.value >= getOracleAmounts(minBet) && msg.value <= getOracleAmounts(maxBet), "E89");

        randNonce++;

        _GameIds.increment();

        uint256 gameid = _GameIds.current();

        GameMaker storage gamemaker = gameMaker[gameid];
        TimeStamps storage timestamps = timeStamps[gameid];

        (uint nftid, uint packid,, uint mintClass,) = getPVPNFTinfo(_tokenid);

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, rollMod); //get user roll 0-69
        uint256 strengthroll = Inserter(directory.getInserter()).getRandMod(randNonce+1, _tokenid, strenMod); 
        uint256 weaknessroll = Inserter(directory.getInserter()).getRandMod(randNonce+2, _tokenid, weakMod); 

        gamemaker.makerAddress = _msgSender();
        gamemaker.makerTokenID = uint16(_tokenid);
        gamemaker.makerNFTPack = uint8(packid);
        gamemaker.makerNFTID = uint8(nftid);
        gamemaker.makerStrong = uint8(getStrength(packid)); 
        gamemaker.makerStrongRoll = uint8(strengthroll++);
        gamemaker.makerWeak = uint8(getWeakness(packid)); 
        gamemaker.makerWeakRoll = uint8(weaknessroll++);  
        gamemaker.makerNFTratio = uint8(mintClass);
        gamemaker.makerRoll = uint8(roll.add(rollNormalizer));
        timestamps.timeStart = uint64(block.timestamp);
        timestamps.timeExpires = uint64(block.timestamp.add(timeEnding));
        gamemaker.makerBNBamount = uint128(msg.value);
        gamemaker.open = true;
        gamemaker.makerGenus = ITeazePacks(directory.getPacks()).getGenus(packid);

        IERC721(directory.getNFT()).safeTransferFrom(_msgSender(), address(this), _tokenid);

        userGames[_msgSender()]++;

        uint usergames = userGames[_msgSender()];

        userGameIDs[_msgSender()][usergames]= gameid;

        opengamearray.push(gameid);

    }

    function acceptPVP(uint _tokenid, uint _gameid) external payable nonReentrant {

        require(ITeazeFarm(directory.getFarm()).getUserStaked(_msgSender()), "E35");
        require(!ISimpCrates(directory.getCrates()).claimedNFT(_tokenid), "E97");
        
        GameMaker storage gamemaker = gameMaker[_gameid];
        GameTaker storage gameresult = gameTaker[_gameid];
        TimeStamps storage timestamps = timeStamps[_gameid];

        (uint nftid, uint packid,, uint mintClass,) = getPVPNFTinfo(_tokenid);

        require(msg.value >= getNFTdelta(mintClass, _gameid), "E89");
        require(_msgSender() != gamemaker.makerAddress, "102");

        randNonce++;

        uint256 roll = Inserter(directory.getInserter()).getRandMod(randNonce, _tokenid, rollMod); //get user roll 0-69
        uint256 strengthroll = Inserter(directory.getInserter()).getRandMod(randNonce+1, _tokenid, strenMod); 
        uint256 weaknessroll = Inserter(directory.getInserter()).getRandMod(randNonce+2, _tokenid, weakMod); 

        gameresult.takerAddress = _msgSender(); 
        gameresult.takerTokenID = uint16(_tokenid);
        gameresult.takerNFTPack = uint8(packid);
        gameresult.takerNFTID = uint8(nftid);
        gameresult.takerStrong = uint8(getStrength(packid)); 
        gameresult.takerStrongRoll = uint8(strengthroll++);
        gameresult.takerWeak = uint8(getWeakness(packid)); 
        gameresult.takerWeakRoll = uint8(weaknessroll++); 
        gameresult.takerMintClass = uint8(mintClass);
        gameresult.takerRoll = uint8(roll.add(rollNormalizer));
        timestamps.timeEnds = uint64(block.timestamp);
        gameresult.takerBNBamount = uint128(msg.value);
        gameresult.takerGenus = ITeazePacks(directory.getPacks()).getGenus(packid);
    
        userGames[_msgSender()]++;

        uint usergames = userGames[_msgSender()];

        userGameIDs[_msgSender()][usergames]= _gameid;

        gamemaker.open = false;

        distributeOutcome(_gameid);
        closeGame(_gameid, true);
        
    }

    function getStrength(uint _packid) internal view returns (uint) {

        uint packs = ITeazePacks(directory.getPacks()).getTotalPacks();

        uint256 strengthroll = Inserter(directory.getInserter()).getRandMod(randNonce, _packid, packs); //get random pack

        return strengthroll++; //Normalize cause there's no zero pack

    }

    function getWeakness(uint _packid) internal view returns (uint) {

        (, string[] memory genus) = ITeazePacks(directory.getPacks()).getAllGenus();

        uint256 genusroll = Inserter(directory.getInserter()).getRandMod(randNonce, _packid, genus.length); //get random pack

        return genusroll; 

    }

    function viewGameMaker(uint _gameID) external view returns (
        address makerAddress,
        uint16 makerTokenID,
        uint8 makerNFTPack, 
        uint8 makerNFTID, 
        uint8 makerNFTratio,
        uint128 makerBNBamount,
        string memory makerGenus,
        bool open
    ) {

        GameMaker storage gamemaker = gameMaker[_gameID];

        return (
            gamemaker.makerAddress,
            gamemaker.makerTokenID,
            gamemaker.makerNFTPack, 
            gamemaker.makerNFTID, 
            gamemaker.makerNFTratio,
            gamemaker.makerBNBamount,
            gamemaker.makerGenus,
            gamemaker.open
        );

    }

    function getMakerInfo(uint _gameId) external view returns (
        
        uint8 makerStrong,
        uint8 makerStrongRoll,
        uint8 makerWeak,
        uint8 makerWeakRoll,
        uint8 makerRoll
        
    ) {

        GameMaker storage gamemaker = gameMaker[_gameId];

        if (authorized[_msgSender()] || gamemaker.makerAddress == _msgSender() || !gamemaker.open) {

            return (

                gamemaker.makerStrong,
                gamemaker.makerStrongRoll,
                gamemaker.makerWeak,
                gamemaker.makerWeakRoll,
                gamemaker.makerRoll
            );

        }

    }

    function getNFTdelta(uint _mintClass, uint _gameId) public view returns (uint _amount) {

        GameMaker storage gamemaker = gameMaker[_gameId];
        uint amount;

        if(gamemaker.makerNFTratio == _mintClass) {
            return gamemaker.makerBNBamount;
        }

        if(gamemaker.makerNFTratio > _mintClass) { //maker NFT higher rarity
            
            return amount = uint(gamemaker.makerBNBamount).mul(uint(gamemaker.makerNFTratio).sub(_mintClass--)).mul(makerNFTnumerator).div(100);
        }

        if(gamemaker.makerNFTratio < _mintClass) { //maker NFT lower rarity
            amount = uint(uint(gamemaker.makerBNBamount).mul(100).div(uint((_mintClass++).sub(gamemaker.makerNFTratio)).mul(100))).mul(takerNFTnumerator).div(100);
            return amount.add(gameFee);
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
        GameMaker storage gamemaker = gameMaker[_gameId];
        GameTaker storage gameresult = gameTaker[_gameId];
        TimeStamps storage timestamps = timeStamps[_gameId];

        if (gamemaker.open) {
            require(gamemaker.makerAddress == _msgSender(), "E90");
        } else {
            return;
        }

        require(block.timestamp >= timestamps.timeExpires, "E96");

        gamemaker.open = false;
        gameresult.winner = "Expired";

        payable(_msgSender()).transfer(uint(gamemaker.makerBNBamount).sub(gameFee));
        IERC721(directory.getNFT()).safeTransferFrom(address(this), _msgSender(), gamemaker.makerTokenID);

        closeGame(_gameId, false);

        totalFees = totalFees.add(gameFee);
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

        for(uint x=0;x<games;x++) {

            gameids[x] = userGameIDs[_user][x];

        }

        return(games, gameids);
    }

    function getUserOpenGames(address _user) external view returns (uint[] memory) {

        (uint games, uint[] memory gameids) = getAllUserGames(_user);

        uint[] memory opengameids = new uint[](games);

        uint count;

        for(uint x=0;x<games;x++) {

            GameMaker storage gamemaker = gameMaker[gameids[x]];

            if(gamemaker.open) {

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

        for(uint x=0;x<games;x++) {

            GameMaker storage gamemaker = gameMaker[gameids[x]];

            if(!gamemaker.open) {

                closedgameids[count] = userGameIDs[_user][x];

                count++;

            }

        }

        return closedgameids;

    }

    function distributeOutcome(uint _gameid) internal {

        GameMaker storage gamemaker = gameMaker[_gameid];
        GameTaker storage gameresult = gameTaker[_gameid];

        uint makerTempRoll = gamemaker.makerRoll;
        uint takerTempRoll = gameresult.takerRoll;
        (, string[] memory genus) = ITeazePacks(directory.getPacks()).getAllGenus();

        //maker strength
        if(gamemaker.makerStrong == gameresult.takerNFTPack) {
            makerTempRoll = makerTempRoll.add(gamemaker.makerStrongRoll);
        }

        //taker strength
        if(gameresult.takerStrong == gamemaker.makerNFTPack) {
            takerTempRoll = takerTempRoll.add(gameresult.takerStrongRoll);
        }

        //maker weakness
        if(keccak256(bytes(genus[gamemaker.makerWeak])) == keccak256(bytes(gameresult.takerGenus))) {
            makerTempRoll = uint(makerTempRoll).sub(gamemaker.makerWeakRoll);
        } 

        //taker weakness
        if(keccak256(bytes(genus[gameresult.takerWeak])) == keccak256(bytes(gamemaker.makerGenus))) {
            takerTempRoll = uint(takerTempRoll).sub(gameresult.takerWeakRoll);
        } 

        if(makerTempRoll == takerTempRoll) { //tie

            gameresult.winner = "Tie";

            payable(gamemaker.makerAddress).transfer(uint(gamemaker.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gamemaker.makerAddress, gamemaker.makerTokenID);

            payable(gameresult.takerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));

            totalFees = totalFees.add(gameFee.mul(2));

        } 
        
        if(makerTempRoll > takerTempRoll) { //maker wins

            gameresult.winner = "Maker";
            gameresult.runnerUpAmount = uint64(loserSBXamount.mul(gameresult.takerMintClass));
            ITeazeFarm(directory.getFarm()).increaseSBXBalance(_msgSender(), gameresult.runnerUpAmount);

            payable(gamemaker.makerAddress).transfer(uint(gamemaker.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gamemaker.makerAddress, gamemaker.makerTokenID);

            payable(gamemaker.makerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(gameresult.takerAddress, gamemaker.makerAddress, gameresult.takerTokenID);

            totalFees = totalFees.add(gameFee.mul(2));

        } 

        if(makerTempRoll < takerTempRoll) { //taker wins

            gameresult.winner = "Taker";
            gameresult.runnerUpAmount = uint64(loserSBXamount.mul(gamemaker.makerNFTratio));
            ITeazeFarm(directory.getFarm()).increaseSBXBalance(gamemaker.makerAddress, gameresult.runnerUpAmount);

            payable(gameresult.takerAddress).transfer(uint(gamemaker.makerBNBamount).sub(gameFee));
            IERC721(directory.getNFT()).safeTransferFrom(address(this), gameresult.takerAddress, gamemaker.makerTokenID);

            payable(gameresult.takerAddress).transfer(uint(gameresult.takerBNBamount).sub(gameFee));

            totalFees = totalFees.add(gameFee.mul(2));

        } 

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

    function viewopenGames() external view returns (uint256[] memory opengames){

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

    function changeweakMod(uint _weakMod) external onlyAuthorized {
        require(weakMod >=5, "E96");
        require(weakMod < rollNormalizer, "E97");
        weakMod = _weakMod;
    }

    function changeRollParams(uint _rollMod, uint _rollNormalizer) external onlyAuthorized {
        require(_rollMod >= 50, "E98");
        require(_rollMod > rollNormalizer, "E99");
        require(_rollNormalizer > weakMod, "E100");

        rollMod = _rollMod;
        rollNormalizer = _rollNormalizer;
    }

    function changeNumerators(uint _maker, uint _taker) external onlyAuthorized {
        require(_maker < _taker, "E101");
        makerNFTnumerator = _maker;
        takerNFTnumerator = _taker;
    }

    function rescueETHFromContract() external onlyAuthorized {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyAuthorized {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }

    function sweepFees() internal {
        if(totalFees > gameFee.mul(10)) {
            payable(directory.getLotto()).transfer(totalFees.mul(50).div(100));
            payable(directory.getCrates()).transfer(totalFees.mul(50).div(100));
            totalFees = 0;
        }         
    }
}
