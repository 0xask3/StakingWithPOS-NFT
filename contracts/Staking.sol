//**  Staking Contract */
//** Author Grim */

//SPDX-License-Identifier: UNLICENSED

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

pragma solidity ^0.8.10;

contract Staking is Ownable, ERC721 {
    using SafeMath for uint256;
    using SafeMath for uint16;

    /**
     *
     * @dev User reflects the info of each user
     *
     *
     * @param {total_invested} how many tokens the user staked
     * @param {total_withdrawn} how many tokens withdrawn so far
     * @param {lastPayout} time at which last claim was done
     * @param {depositTime} Time of last deposit
     * @param {nftId} NFT identifier for current user
     * @param {totalClaimed} Total claimed by the user
     *
     */
    struct User {
        uint256 total_invested;
        uint256 total_withdrawn;
        uint256 lastPayout;
        uint256 depositTime;
        uint256 nftId;
        uint256 totalClaimed;
    }

    /**
     *
     * @dev PoolInfo reflects the info of each pools
     *
     * To improve precision, we provide APY with an additional zero. So if APY is 12%, we provide
     * 120 as input.lockPeriodInDays would be the number of days which the claim is locked. So if we want to
     * lock claim for 1 month, lockPeriodInDays would be 30.
     *
     * @param {apy} Percentage of yield produced by the pool
     * @param {lockPeriodInDays} Amount of time claim will be locked
     * @param {totalDeposit} Total deposit in the pool
     * @param {startDate} starting time of pool
     * @param {endDate} ending time of pool in unix timestamp
     * @param {minContrib} Minimum amount to be staked
     * @param {maxContrib} Maximum amount that can be staked
     * @param {hardCap} Maximum amount a pool can hold
     *
     */

    struct Pool {
        uint16 apy;
        uint16 lockPeriodInDays;
        uint256 totalDeposit;
        uint256 startDate;
        uint256 endDate;
        uint256 minContrib;
        uint256 maxContrib;
        uint256 hardCap;
    }

    IERC20 private token; //Token address
    address private feeAddress; //Address which receives fee
    uint8 private feePercent; //Percentage of fee deducted (/1000)

    uint256 public totalNFT; //Total amount of NFT minted

    mapping(uint256 => mapping(address => User)) public users;
    mapping(uint256 => address) public minterOf;

    Pool[] public poolInfo;

    event Stake(address indexed addr, uint256 amount);
    event Claim(address indexed addr, uint256 amount);

    constructor(address _token) ERC721("Staking NFT", "NFT") {
        token = IERC20(_token);
        feeAddress = msg.sender;
        feePercent = 0;

        _safeMint(msg.sender, totalNFT); //Minting first NFt to owner
        totalNFT++;
    }

    receive() external payable {
        revert("Native deposit not supported");
    }

    /**
     *
     * @dev get length of the pools
     *
     * @return {uint256} length of the pools
     *
     */
    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    /**
     *
     * @dev get info of all pools
     *
     * @return {PoolInfo[]} Pool info struct
     *
     */
    function getPools() public view returns (Pool[] memory) {
        return poolInfo;
    }

    /**
     *
     * @dev add new period to the pool, only available for owner
     *
     */
    function add(
        uint16 _apy,
        uint16 _lockPeriodInDays,
        uint256 _endDate,
        uint256 _minContrib,
        uint256 _maxContrib,
        uint256 _hardCap
    ) public onlyOwner {
        poolInfo.push(
            Pool({
                apy: _apy,
                lockPeriodInDays: _lockPeriodInDays,
                totalDeposit: 0,
                startDate: block.timestamp,
                endDate: _endDate,
                minContrib: _minContrib,
                maxContrib: _maxContrib,
                hardCap: _hardCap
            })
        );
    }

    /**
     *
     * @dev update the given pool's Info
     *
     */
    function set(
        uint256 _pid,
        uint16 _apy,
        uint16 _lockPeriodInDays,
        uint256 _endDate,
        uint256 _minContrib,
        uint256 _maxContrib,
        uint256 _hardCap
    ) public onlyOwner {
        require(_pid < poolLength(), "Invalid pool Id");

        poolInfo[_pid].apy = _apy;
        poolInfo[_pid].lockPeriodInDays = _lockPeriodInDays;
        poolInfo[_pid].endDate = _endDate;
        poolInfo[_pid].minContrib = _minContrib;
        poolInfo[_pid].maxContrib = _maxContrib;
        poolInfo[_pid].hardCap = _hardCap;
    }

    /**
     *
     * @dev depsoit tokens to staking for  allocation
     *
     * @param {_pid} Id of the pool
     * @param {_amount} Amount to be staked
     *
     * @return {bool} Status of stake
     *
     */
    function stake(uint8 _pid, uint256 _amount) external returns (bool) {
        require(
            token.allowance(msg.sender, address(this)) >= _amount,
            " : Set allowance first!"
        );

        bool success = token.transferFrom(msg.sender, address(this), _amount);
        require(success, " : Transfer failed");

        _stake(_pid, msg.sender, _amount);

        return success;
    }

    function _stake(
        uint8 _pid,
        address _sender,
        uint256 _amount
    ) internal {
        User storage user = users[_pid][_sender];
        Pool storage pool = poolInfo[_pid];

        if (user.nftId == 0) {
            _safeMint(_sender, totalNFT);
            minterOf[totalNFT] = msg.sender;
            user.nftId = totalNFT;
            totalNFT++;
        }

        require(
            _amount >= pool.minContrib &&
                _amount.add(user.total_invested) <= pool.maxContrib,
            "Invalid amount!"
        );

        require(pool.totalDeposit.add(_amount) <= pool.hardCap, "Pool is full");

        uint256 stopDepo = pool.endDate.sub(pool.lockPeriodInDays.mul(1 days));

        require(
            block.timestamp <= stopDepo,
            "Staking is disabled for this pool"
        );

        user.total_invested = user.total_invested.add(_amount);
        pool.totalDeposit = pool.totalDeposit.add(_amount);
        user.lastPayout = block.timestamp;
        user.depositTime = block.timestamp;

        emit Stake(_sender, _amount);
    }

    /**
     *
     * @dev claim accumulated  reward for a single pool
     *
     * @param {_pid} pool identifier
     8 @param {_nftId} NFT id of owner
     *
     * @return {bool} status of claim
     */

    function claim(uint8 _pid, uint256 _nftId) public returns (bool) {
        require(ownerOf(_nftId) == msg.sender, "You don't own the NFT");
        address minter = minterOf[_nftId];

        require(canClaim(_pid, minter), "Reward still in locked state");

        _claim(_pid, minter);

        return true;
    }

    /**
     *
     * @dev check whether user can claim or not
     *
     * @param {_pid}  id of the pool
     * @param {_addr} address of the user
     *
     * @return {bool} Status of claim
     *
     */

    function canClaim(uint8 _pid, address _addr) public view returns (bool) {
        User storage user = users[_pid][_addr];
        Pool storage pool = poolInfo[_pid];

        return (block.timestamp >=
            user.depositTime.add(pool.lockPeriodInDays.mul(1 days)));
    }

    /**
     *
     * @dev withdraw tokens from Staking
     *
     * @param {_pid} id of the pool
     * @param {_amount} amount to be unstaked
     * @param {_nftId} NFT id of owner
     *
     * @return {bool} Status of stake
     *
     */
    function unStake(
        uint8 _pid,
        uint256 _amount,
        uint256 _nftId
    ) external returns (bool) {
        require(ownerOf(_nftId) == msg.sender, "You don't own the NFT");
        address minter = minterOf[_nftId];

        User storage user = users[_pid][minter];
        Pool storage pool = poolInfo[_pid];

        require(user.total_invested >= _amount, "You don't have enough funds");

        require(canClaim(_pid, minter), "Stake still in locked state");

        _claim(_pid, minter);

        pool.totalDeposit = pool.totalDeposit.sub(_amount);
        user.total_invested = user.total_invested.sub(_amount);

        safeTransfer(msg.sender, _amount);

        return true;
    }

    function _claim(uint8 _pid, address _addr) internal {
        User storage user = users[_pid][_addr];

        uint256 amount = payout(_pid, _addr);

        if (amount > 0) {
            user.total_withdrawn = user.total_withdrawn.add(amount);

            uint256 feeAmount = amount.mul(feePercent).div(1000);

            safeTransfer(feeAddress, feeAmount);

            amount = amount.sub(feeAmount);

            safeTransfer(msg.sender, amount);

            user.lastPayout = block.timestamp;

            user.totalClaimed = user.totalClaimed.add(amount);
        }

        emit Claim(_addr, amount);
    }

    /**
     *
     * @dev View function to calculate claimable amount
     *
     */

    function payout(uint8 _pid, address _addr)
        public
        view
        returns (uint256 value)
    {
        User storage user = users[_pid][_addr];
        Pool storage pool = poolInfo[_pid];

        uint256 from = user.lastPayout > user.depositTime
            ? user.lastPayout
            : user.depositTime;
        uint256 to = block.timestamp > pool.endDate
            ? pool.endDate
            : block.timestamp;

        if (from < to) {
            value = value.add(
                user.total_invested.mul(to.sub(from)).mul(pool.apy).div(
                    365 days * 1000
                )
            );
        }

        return value;
    }

    /**
     *
     * @dev safe  transfer function, require to have enough  to transfer
     *
     */
    function safeTransfer(address _to, uint256 _amount) internal {
        uint256 bal = token.balanceOf(address(this));
        if (_amount > bal) {
            token.transfer(_to, bal);
        } else {
            token.transfer(_to, _amount);
        }
    }

    /**
     *
     * @dev update fee values
     *
     */
    function updateFeeValues(uint8 _feePercent, address _feeWallet)
        public
        onlyOwner
    {
        feePercent = _feePercent;
        feeAddress = _feeWallet;
    }
}
