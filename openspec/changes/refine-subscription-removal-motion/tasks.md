## 1. Removal Motion

- [x] 1.1 Replace the home-row removal modifier with the defined low-amplitude settle and vertical-collapse motion.
- [x] 1.2 Remove perspective rotation, blur, and large horizontal translation from the normal removal path.
- [x] 1.3 Tune the list animation so adjacent active and inactive rows reflow without a visible bounce.

## 2. Accessibility and Recovery

- [x] 2.1 Use an opacity-only transition for removal and recovery when Reduce Motion is enabled.
- [x] 2.2 Retain a restrained recovery transition when a backend deletion request fails.
- [x] 2.3 Keep deletion haptics and the accessible completion toast intact.

## 3. Verification

- [x] 3.1 Build the iOS simulator and device targets.
- [ ] 3.2 Manually verify active removal, inactive permanent deletion, failure recovery, and Reduced Motion behavior in the simulator.
