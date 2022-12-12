// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IJetStaking.sol";

/**
 *    _____                                     .__          __    __
 *   /  _  \  __ _________  ________________    |  |   _____/  |__/  |_  ___________ ___.__.
 *  /  /_\  \|  |  \_  __ \/  _ \_  __ \__  \   |  |  /  _ \   __\   __\/ __ \_  __ <   |  |
 * /    |    \  |  /|  | \(  <_> )  | \// __ \_ |  |_(  <_> )  |  |  | \  ___/|  | \/\___  |
 * \____|__  /____/ |__|   \____/|__|  (____  / |____/\____/|__|  |__|  \___  >__|   / ____|
 *         \/                               \/                              \/       \/
 *
 * @title Aurora Yield Lottery
 * @author Aurora Team
 *
 * @notice This contract allows users to pool together their aurora for a specified
 *         period of time, afterwhich a user is selected at random as the "winner".
 *         The "winner" receives the combined yield generated by all users + initial
 *         stake provided. All users are refunded their initial investment.
 *
 * @dev Two key problems to solve for this are:
 *      - Mechanism to decide winner (one address one ticket, or one aurora one ticket, or something else?)
 *      - Where to get source of randomness - the EVM is inherently deterministic, hence its virtually impossible
 *        to achieve this *within* the blockchain. Blockhash, blockTimestamp, nonce etc. can be gamed easily.
 *
 *     Solution: The source of randomness is achieved thanks to the NEAR blockchain including a random number in
 *               every block. This number is then used to select a winner. There is one caveat however, which is
 *               that near validators can choose to not produce a block if the random number is "not of their liking"
 *               However, I believe this will have minimal impact as this "manipulation" comes with a lot of reputational
 *               and potentially financial cost to the validator.
 */

contract YieldLottery {
    using SafeERC20 for IERC20;

    // Window of time within which users can deposit aurora
    uint256 public openWindow;
    // Cost of 1 ticket
    uint256 public ticketPrice;
    // Admin of the contract
    address public admin;
    // Allows control over deposits
    bool public paused;
    // Aurora token
    IERC20 public aurora;
    // Stream tokens
    IERC20[] public streamTokens;
    // JetStaking
    IJetStaking public jetStaking;
    // Array of epochs
    Epoch[] public epochs;
    // Mapping of epochId => address => Position
    mapping(uint256 => mapping(address => Position[])) public userTickets;
    // Helps to keep track who has claimed
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    enum Status {
        Active,
        Ended
    }

    // Position represents a user's stake
    struct Position {
        uint64 startId;
        uint64 finalId;
    }

    // 1 Epoch == 1 "lottery game"
    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        uint256 initialBal;
        uint256 finalBal;
        uint256 winningId;
        bool withdrawalOpen;
        Status status;
    }

    event Initialized(uint256 Window, uint256 Price);
    event Staked(address indexed user, uint256 indexed epochId, uint64 indexed startId);
    event NewAdmin(address indexed admin);
    event NewTicketPrice(uint256 indexed price);
    event NewTimeWindow(uint256 indexed time);

    modifier onlyAdmin() {
        require(msg.sender == admin, "ONLY_ADMIN_CAN_CALL");
        _;
    }

    modifier notPaused() {
        require(!paused, "CONTRACT_PAUSED");
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), "CANNOT_SET_TO_ZERO");
        admin = _admin;
        paused = true;
    }

    // Initialization of state variables
    function init(
        uint256 _openWindow,
        uint256 _ticketPrice,
        address _aurora,
        address _jetStaking,
        address[] calldata _streamTokens
    ) external onlyAdmin {
        openWindow = _openWindow;
        ticketPrice = _ticketPrice;
        aurora = IERC20(_aurora);
        jetStaking = IJetStaking(_jetStaking);
        for (uint256 i; i < _streamTokens.length;) {
            streamTokens.push(IERC20(_streamTokens[i]));
            unchecked {
                i++;
            }
        }
        aurora.approve(address(jetStaking), type(uint256).max);
        newEpoch();
        paused = false;

        emit Initialized(_openWindow, _ticketPrice);
    }

    // @notice Allows users to buy tickets in the current epoch
    // @param _tickets Amount of tickets to buy
    // @dev Function checks that the epoch is live and within the "betting window"
    //      It then updates a mapping and stakes the user's aurora tokens
    function buyTickets(uint256 _tickets) external notPaused {
        require(_tickets != 0, "TICKET_AMOUNT_MUST_BE_>_0");
        uint256 epochId = epochs.length - 1;
        uint256 cost = _tickets * ticketPrice;
        Epoch memory currentEpoch = epochs[epochId];
        require(currentEpoch.status == Status.Active, "NO_LIVE_EPOCHS");
        require(currentEpoch.startTime + openWindow > block.timestamp, "EPOCH_CLOSED");
        // slither-disable-next-line reentrancy-benign reentrancy-events
        aurora.safeTransferFrom(msg.sender, address(this), cost);
        Position memory newPosition = Position({
            startId: uint64(currentEpoch.initialBal / ticketPrice),
            finalId: uint64(currentEpoch.initialBal / ticketPrice + _tickets - 1)
        });
        userTickets[epochId][msg.sender].push(newPosition);
        epochs[epochId].initialBal += cost;

        emit Staked(msg.sender, epochId, newPosition.startId);
    }

    // @notice Allows users to claim their tokens after epoch is finished
    // @param _epochId Epoch that they want to claim their tokens for
    // @dev Function makes sure said epoch: is concluded, the 2 day withdrawal wait
    //      is over. and user hasn't already claimed. It then transfers the user's
    //      initial depposit back, and checks if the user is the winner to send the
    //      yield generated.
    function claimTickets(uint256 _epochId) public {
        Epoch memory epoch = epochs[_epochId];
        require(epoch.status == Status.Ended, "EPOCH_NOT_CONCLUDED");
        require(epoch.withdrawalOpen, "WITHDRAWAL_UNAVAILABLE");
        require(!hasClaimed[_epochId][msg.sender], "ALREADY_CLAIMED");
        Position[] memory userPositions = userTickets[_epochId][msg.sender];
        uint256 balance;
        for (uint256 i = 0; i < userPositions.length;) {
            balance += (userPositions[i].finalId - userPositions[i].startId + 1) * ticketPrice;
            if (epoch.winningId >= userPositions[i].startId && epoch.winningId <= userPositions[i].finalId) {
                uint256 prize = epoch.finalBal - epoch.initialBal;
                balance += prize;
                for (uint256 j = 0; j < streamTokens.length;) {
                     // slither-disable-next-line calls-loop
                    uint256 bal = streamTokens[j].balanceOf(address(this));
                    // slither-disable-next-line reentrancy-benign reentrancy-events
                    streamTokens[j].safeTransfer(msg.sender, bal);
                    unchecked {
                        j++;
                    }
                }
            }
            unchecked {
                i++;
            }
        }
        // slither-disable-next-line reentrancy-benign reentrancy-events
        aurora.safeTransfer(msg.sender, balance);

        hasClaimed[_epochId][msg.sender] = true;
    }

    function claimLatest() external {
        claimTickets(epochs.length - 2);
    }

    // @notice Allows admin to close an epoch and computes the winner
    // @dev Function updates epoch variables and moves all rewardstoPending.
    function concludeEpoch() external onlyAdmin {
        uint256 epochId = epochs.length - 1;
        Epoch storage currentEpoch = epochs[epochId];
        require(currentEpoch.status == Status.Active, "NO_LIVE_EPOCH");
        currentEpoch.winningId = computeWinner(epochId);
        currentEpoch.endTime = block.timestamp;
        currentEpoch.status = Status.Ended;
        uint256 auroraBal = (jetStaking.getTotalAmountOfStakedAurora() * jetStaking.getUserShares(address(this)))
            / jetStaking.totalAuroraShares();
        currentEpoch.finalBal = auroraBal;
        jetStaking.moveAllRewardsToPending();
        jetStaking.unstakeAll();
    }

    // @notice Allows admin to withdraw tokens once the 2 day delay is over
    // @notice _epochId Allows function to know which epochId to update
    function withdraw(uint256 _epochId) external onlyAdmin {
        // slither-disable-next-line reentrancy-benign
        jetStaking.withdrawAll();
        epochs[_epochId].withdrawalOpen = true;
    }

    // @notice Creates a new epoch and pushes to the array
    function newEpoch() public onlyAdmin {
        epochs.push(Epoch(block.timestamp, 0, 0, 0, 0, false, Status.Active));
    }

    /*/////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    /////////////////////////////////////////////////////*/

    function randomSeed() public returns (uint256) {
        bytes32[1] memory value;

        assembly {
            let ret := call(gas(), 0xc104f4840573bed437190daf5d2898c2bdf928ac, 0, 0, 0, value, 32)
        }

        return uint256(value[0]);
    }

    // @notice Function computes the winner for a specific epoch
    // @param epochId Id of epoch we want to compute winner for
    // @dev The winner is computed by getting a random uint256 number
    //      We then divide this random number by the total aurora deposited
    //      in the specified epoch, and take the remainder.
    function computeWinner(uint256 epochId) public returns (uint256 winningNum) {
        uint256 randNum = randomSeed();
        uint256 totalTickets = epochs[epochId].initialBal / ticketPrice;
        winningNum = (randNum % totalTickets);
    }

    function stake() external onlyAdmin {
        jetStaking.stake(aurora.balanceOf(address(this)));
    }

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "CANNOT_SET_TO_ZERO");
        admin = _admin;

        emit NewAdmin(_admin);
    }

    function setOpenWindow(uint256 _time) external onlyAdmin {
        openWindow = _time;

        emit NewTimeWindow(_time);
    }

    function setTicketPrice(uint256 _price) external onlyAdmin {
        ticketPrice = _price;

        emit NewTicketPrice(_price);
    }

    function pause() external onlyAdmin {
        paused = true;
    }

    function unPause() external onlyAdmin {
        paused = false;
    }

    function getEpoch(uint256 _epochId)
        public
        view
        returns (uint256, uint256, uint256, uint256, uint256, bool, Status)
    {
        Epoch memory epoch = epochs[_epochId];
        return (
            epoch.startTime,
            epoch.endTime,
            epoch.initialBal,
            epoch.finalBal,
            epoch.winningId,
            epoch.withdrawalOpen,
            epoch.status
        );
    }
}
