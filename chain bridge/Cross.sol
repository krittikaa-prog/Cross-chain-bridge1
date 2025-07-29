// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title CrossChainBridge
 * @dev A cross-chain bridge contract for transferring tokens between different blockchains
 * @notice This contract handles token locking/unlocking and minting/burning for cross-chain transfers
 */
contract CrossChainBridge is ReentrancyGuard, Ownable, Pausable {
    
    // Events
    event TokensLocked(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 indexed destinationChainId,
        bytes32 bridgeId
    );
    
    event TokensUnlocked(
        address indexed user,
        address indexed token,
        uint256 amount,
        bytes32 indexed bridgeId
    );
    
    event BridgeRequestProcessed(
        bytes32 indexed bridgeId,
        address indexed user,
        bool success
    );
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    
    // Structs
    struct BridgeRequest {
        address user;
        address token;
        uint256 amount;
        uint256 sourceChainId;
        uint256 destinationChainId;
        bool processed;
        uint256 validatorConfirmations;
    }
    
    // State variables
    mapping(address => bool) public validators;
    mapping(bytes32 => BridgeRequest) public bridgeRequests;
    mapping(bytes32 => mapping(address => bool)) public validatorConfirmations;
    mapping(address => bool) public supportedTokens;
    mapping(uint256 => bool) public supportedChains;
    
    uint256 public requiredConfirmations;
    uint256 public validatorCount;
    uint256 public bridgeFee; // Fee in wei
    
    modifier onlyValidator() {
        require(validators[msg.sender], "Not a validator");
        _;
    }
    
    modifier onlySupportedToken(address token) {
        require(supportedTokens[token], "Token not supported");
        _;
    }
    
    modifier onlySupportedChain(uint256 chainId) {
        require(supportedChains[chainId], "Chain not supported");
        _;
    }
    
    constructor(uint256 _requiredConfirmations, uint256 _bridgeFee) Ownable(msg.sender) {
        requiredConfirmations = _requiredConfirmations;
        bridgeFee = _bridgeFee;
        
        // Add deployer as initial validator
        validators[msg.sender] = true;
        validatorCount = 1;
        
        emit ValidatorAdded(msg.sender);
    }
    
    /**
     * @dev Lock tokens to initiate cross-chain transfer
     * @param token Address of the token to lock
     * @param amount Amount of tokens to lock
     * @param destinationChainId Target chain ID for the transfer
     * @return bridgeId Unique identifier for this bridge request
     */
    function lockTokens(
        address token,
        uint256 amount,
        uint256 destinationChainId
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        onlySupportedToken(token) 
        onlySupportedChain(destinationChainId)
        returns (bytes32 bridgeId) 
    {
        require(amount > 0, "Amount must be greater than 0");
        require(msg.value >= bridgeFee, "Insufficient bridge fee");
        require(destinationChainId != block.chainid, "Cannot bridge to same chain");
        
        // Generate unique bridge ID
        bridgeId = keccak256(
            abi.encodePacked(
                msg.sender,
                token,
                amount,
                block.chainid,
                destinationChainId,
                block.timestamp,
                block.number
            )
        );
        
        // Transfer tokens from user to bridge contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Store bridge request
        bridgeRequests[bridgeId] = BridgeRequest({
            user: msg.sender,
            token: token,
            amount: amount,
            sourceChainId: block.chainid,
            destinationChainId: destinationChainId,
            processed: false,
            validatorConfirmations: 0
        });
        
        emit TokensLocked(msg.sender, token, amount, destinationChainId, bridgeId);
        
        return bridgeId;
    }
    
    /**
     * @dev Unlock tokens on destination chain (called by validators)
     * @param bridgeId Unique identifier of the bridge request
     * @param user Address to receive the unlocked tokens
     * @param token Address of the token to unlock
     * @param amount Amount of tokens to unlock
     */
    function unlockTokens(
        bytes32 bridgeId,
        address user,
        address token,
        uint256 amount
    ) 
        external 
        onlyValidator 
        nonReentrant 
        whenNotPaused 
        onlySupportedToken(token) 
    {
        require(!validatorConfirmations[bridgeId][msg.sender], "Already confirmed");
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be greater than 0");
        
        // Record validator confirmation
        validatorConfirmations[bridgeId][msg.sender] = true;
        
        // Check if bridge request exists, if not create it
        if (bridgeRequests[bridgeId].user == address(0)) {
            bridgeRequests[bridgeId] = BridgeRequest({
                user: user,
                token: token,
                amount: amount,
                sourceChainId: 0, // Will be set by source chain
                destinationChainId: block.chainid,
                processed: false,
                validatorConfirmations: 1
            });
        } else {
            bridgeRequests[bridgeId].validatorConfirmations++;
        }
        
        // If enough confirmations, execute the unlock
        if (bridgeRequests[bridgeId].validatorConfirmations >= requiredConfirmations && 
            !bridgeRequests[bridgeId].processed) {
            
            bridgeRequests[bridgeId].processed = true;
            
            // Transfer tokens to user
            IERC20(token).transfer(user, amount);
            
            emit TokensUnlocked(user, token, amount, bridgeId);
            emit BridgeRequestProcessed(bridgeId, user, true);
        }
    }
    
    /**
     * @dev Add a new validator (only owner)
     * @param validator Address of the new validator
     */
    function addValidator(address validator) external onlyOwner {
        require(validator != address(0), "Invalid validator address");
        require(!validators[validator], "Already a validator");
        
        validators[validator] = true;
        validatorCount++;
        
        emit ValidatorAdded(validator);
    }
    
    /**
     * @dev Remove a validator (only owner)
     * @param validator Address of the validator to remove
     */
    function removeValidator(address validator) external onlyOwner {
        require(validators[validator], "Not a validator");
        require(validatorCount > 1, "Cannot remove last validator");
        
        validators[validator] = false;
        validatorCount--;
        
        emit ValidatorRemoved(validator);
    }
    
    /**
     * @dev Get bridge request details
     * @param bridgeId Unique identifier of the bridge request
     * @return BridgeRequest struct containing all request details
     */
    function getBridgeRequest(bytes32 bridgeId) 
        external 
        view 
        returns (BridgeRequest memory) 
    {
        return bridgeRequests[bridgeId];
    }
    
    // Admin functions
    function addSupportedToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token address");
        supportedTokens[token] = true;
    }
    
    function removeSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = false;
    }
    
    function addSupportedChain(uint256 chainId) external onlyOwner {
        require(chainId != 0, "Invalid chain ID");
        supportedChains[chainId] = true;
    }
    
    function removeSupportedChain(uint256 chainId) external onlyOwner {
        supportedChains[chainId] = false;
    }
    
    function updateBridgeFee(uint256 newFee) external onlyOwner {
        bridgeFee = newFee;
    }
    
    function updateRequiredConfirmations(uint256 newRequired) external onlyOwner {
        require(newRequired > 0 && newRequired <= validatorCount, "Invalid confirmation count");
        requiredConfirmations = newRequired;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function withdrawFees() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
}
