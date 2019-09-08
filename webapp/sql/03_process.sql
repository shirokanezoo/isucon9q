INSERT INTO user_stats
SELECT
  `users`.`id` AS `id`
 ,`users`.`id` AS `user_id`
 ,`users`.`num_sell_items`
 ,`users`.`last_bump`
FROM `users`;
ALTER TABLE `users` DROP COLUMN `num_sell_items`;
ALTER TABLE `users` DROP COLUMN `last_bump`;
